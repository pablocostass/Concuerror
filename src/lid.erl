%%%----------------------------------------------------------------------
%%% File        : lid.erl
%%% Authors     : Alkis Gotovos <el3ctrologos@hotmail.com>
%%%               Maria Christakis <christakismaria@gmail.com>
%%% Description : LID interface
%%% Created     : 25 Sep 2010
%%%----------------------------------------------------------------------

-module(lid).

-export([cleanup/1, demonitor/2, from_pid/1, get_linked/1,
	 get_monitored_by/1, link/2, monitor/3, new/2,
	 start/0, stop/0, to_string/1, get_pid/1, unlink/2]).

-export_type([lid/0]).

-include("gen.hrl").

%%%----------------------------------------------------------------------
%%% Definitions
%%%----------------------------------------------------------------------

%% Information kept in the NT_LID table
%%
%% lid      : The process' LID.
%% pid      : The process' pid.
%% nch      : The number of processes spawned by this process.
%% lnk      : A set of LIDs of processes this process is linked to.
%% mns      : A dictionary of {Ref, Lid}, where Lid is a process monitoring
%%            this process and Ref is the corresponding reference.
%% mnd      : A dictionary of {Ref, Lid}, where Lid is a process being
%%            monitored by this process and Ref is the corresponding reference.
-record(info, {lid :: lid(),
	       pid :: pid(),
	       nch :: non_neg_integer(),
	       lnk :: set(),
	       mns :: dict(),
	       mnd :: dict()}).

%% Record element positions, only to be used by ets:update_element.
-define(POS_LID, 2).
-define(POS_PID, 3).
-define(POS_NCH, 4).
-define(POS_LNK, 5).
-define(POS_MNS, 6).
-define(POS_MND, 7).

%%%----------------------------------------------------------------------
%%% Types
%%%----------------------------------------------------------------------

%% The logical id (LID) for each process reflects the process' logical
%% position in the program's "process creation tree" and doesn't change
%% between different runs of the same program (as opposed to erlang pids).
-type lid() :: string().

%%%----------------------------------------------------------------------
%%% User interface
%%%----------------------------------------------------------------------

%% Cleanup all information of a process.
-spec cleanup(lid()) -> 'ok'.

cleanup(Lid) ->
    [#info{pid = Pid, lnk = Linked, mns = Monitors, mnd = Monitored}] =
	ets:lookup(?NT_LID, Lid),
    %% Delete LID table entry of Lid.
    ets:delete(?NT_LID, Lid),
    %% Delete pid table entry.
    ets:delete(?NT_PID, Pid),
    %% Delete all occurrences of Lid in other process' link-sets.
    Fun1 = fun(L, Unused) -> delete_link(L, Lid), Unused end,
    sets:fold(Fun1, ok, Linked),
    %% Delete all occurrences of Lid in other process' monitored dicts.
    Fun2 = fun(R, L, Unused) ->
		   M = get_monitored(L),
		   set_monitored(L, dict:erase(R, M)),
		   Unused
	   end,
    dict:fold(Fun2, ok, Monitors),
    %% Delete all occurrences of Lid in other process' monitors dicts.
    Fun3 = fun(R, L, Unused) ->
		   M = get_monitors(L),
		   set_monitors(L, dict:erase(R, M)),
		   Unused
	   end,
    dict:fold(Fun3, ok, Monitored).

delete_link(Lid1, Lid2) ->
    OldLinked = get_linked(Lid1),
    NewLinked = sets:del_element(Lid2, OldLinked),
    set_linked(Lid1, NewLinked).

%% Remove monitoring information from a LID.
%% If the given reference does not exist return false, otherwise return true.
-spec demonitor(lid(), reference()) -> {'true', lid()} | 'false'.

demonitor(Lid, Ref) ->
    Monitored = get_monitored(Lid),
    case dict:find(Ref, Monitored) of
	{ok, TargetLid} ->
	    TargetMonitors = get_monitors(TargetLid),
	    set_monitored(Lid, dict:erase(Ref, Monitored)),
	    set_monitors(TargetLid, dict:erase(Ref, TargetMonitors)),
	    {true, TargetLid};
	error -> false
    end.

%% Return the LID of process Pid or 'not_found' if mapping not in table.
-spec from_pid(pid()) -> lid() | 'not_found'.

from_pid(Pid) ->
    case ets:lookup(?NT_PID, Pid) of
	[{Pid, Lid}] -> Lid;
	[] -> not_found
    end.

%% Return the LIDs of all processes monitoring process Lid.
-spec get_monitored_by(lid()) -> set().

get_monitored_by(Lid) ->
    Monitors = get_monitors(Lid),
    Fun = fun(_K, V, Set) -> sets:add_element(V, Set) end,
    dict:fold(Fun, sets:new(), Monitors).

%% Link two LIDs.
-spec link(lid(), lid()) -> boolean().

link(Lid1, Lid2) ->
    LinkedTo1 = get_linked(Lid1),
    set_linked(Lid1, sets:add_element(Lid2, LinkedTo1)),
    LinkedTo2 = get_linked(Lid2),
    set_linked(Lid2, sets:add_element(Lid1, LinkedTo2)).

%% Add monitoring information to a LID.
-spec monitor(lid(), lid(), reference()) -> boolean().

monitor(Lid1, Lid2, Ref) ->
    Monitored = get_monitored(Lid1),
    set_monitored(Lid1, dict:store(Ref, Lid2, Monitored)),
    Monitors = get_monitors(Lid2),
    set_monitors(Lid2, dict:store(Ref, Lid1, Monitors)).

%% "Register" a new process spawned by the process with LID `ParentLid`.
%% Pid is the new process' erlang pid.
%% If called without a `noparent' argument, it "registers" the first process.
%% Return the LID of the newly "registered" process.
-spec new(pid(), lid() | 'noparent') -> lid().

new(Pid, noparent) ->
    %% The first process has LID = "P1", has no children spawned at init,
    %% has the default list of flags and is not linked to any processes.
    Lid = "P1",
    Info = #info{lid = Lid, pid = Pid, nch = 0, lnk = sets:new(),
		 mns = dict:new(), mnd = dict:new()},
    ets:insert(?NT_LID, Info),
    ets:insert(?NT_PID, {Pid, Lid}),
    Lid;
new(Pid, ParentLid) ->
    Children = get_children(ParentLid),
    %% Create new process' Lid
    Lid = lists:concat([ParentLid, ".", Children + 1]),
    %% Update parent info (increment children counter).
    set_children(ParentLid, Children + 1),
    %% Insert child, flag and linking info.
    Info = #info{lid = Lid, pid = Pid, nch = 0, lnk = sets:new(),
		 mns = dict:new(), mnd = dict:new()},
    ets:insert(?NT_LID, Info),
    ets:insert(?NT_PID, {Pid, Lid}),
    Lid.

%% Initialize LID tables.
%% Must be called before any other call to lid interface functions.
-spec start() -> ets:tid() | atom().

start() ->
    %% Table for storing process info.
    ets:new(?NT_LID, [named_table, {keypos, 2}]),
    %% Table for reverse lookup (Pid -> Lid) purposes.
    %% Its elements are of the form {Pid, Lid}.
    ets:new(?NT_PID, [named_table]).

%% Clean up LID tables.
-spec stop() -> 'true'.

stop() ->
    ets:delete(?NT_LID),
    ets:delete(?NT_PID).

-spec to_string(lid()) -> string().

to_string(Lid) ->
    "P" ++ Lid.

%% Unlink two LIDs.
-spec unlink(lid(), lid()) -> boolean().

unlink(Lid1, Lid2) ->
    delete_link(Lid1, Lid2),
    delete_link(Lid2, Lid1).

%%%----------------------------------------------------------------------
%%% Getter and setter functions
%%%----------------------------------------------------------------------

%% Return the erlang pid of the process Lid.
-spec get_pid(lid()) -> pid() | 'not_found'.

get_pid(Lid) ->
    case ets:lookup(?NT_LID, Lid) of
	[] -> 'not_found';
	[#info{pid = Pid}] -> Pid
    end.

get_children(Lid) ->
    [#info{nch = Children}] = ets:lookup(?NT_LID, Lid),
    Children.

%% Return the LIDs of all processes linked to process Lid.
-spec get_linked(lid()) -> set().

get_linked(Lid) ->
    [#info{lnk = Linked}] = ets:lookup(?NT_LID, Lid),
    Linked.

get_monitors(Lid) ->
    [#info{mns = Monitors}] = ets:lookup(?NT_LID, Lid),
    Monitors.

get_monitored(Lid) ->
    [#info{mnd = Monitored}] = ets:lookup(?NT_LID, Lid),
    Monitored.

set_children(Lid, Children) ->
    ets:update_element(?NT_LID, Lid, {?POS_NCH, Children}).

set_linked(Lid, Linked) ->
    ets:update_element(?NT_LID, Lid, {?POS_LNK, Linked}).

set_monitors(Lid, Monitors) ->
    ets:update_element(?NT_LID, Lid, {?POS_MNS, Monitors}).

set_monitored(Lid, Monitored) ->
    ets:update_element(?NT_LID, Lid, {?POS_MND, Monitored}).
