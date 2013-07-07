%% -*- erlang-indent-level: 2 -*-

-module(concuerror_dependencies).

-export([dependent/2]).

%%------------------------------------------------------------------------------

-define(DEBUG, true).
-include("concuerror.hrl").

%%------------------------------------------------------------------------------

%% The first event happens before the second.

-spec dependent(event_info(), event_info()) -> boolean().

dependent(#builtin_event{mfa = MFA1}, #builtin_event{mfa = MFA2}) ->
  dependent_built_in(MFA1, MFA2);

dependent(#builtin_event{mfa = MFA}, #exit_event{} = Exit) ->
  dependent_exit(Exit, MFA);
dependent(#exit_event{} = Exit, #builtin_event{} = Builtin) ->
  dependent(Builtin, Exit);

dependent(#builtin_event{mfa = {erlang,process_flag,[trap_exit,New]}} = Builtin,
          #message_event{recipient = Recipient, type = Type}) ->
  #builtin_event{actor = Actor, result = Old} = Builtin,
  R = New =/= Old andalso
    Type =:= exit_signal andalso
    Actor =:= Recipient,
  ?debug("Testing: ~p~n",[R]),
  R;
dependent(#message_event{} = Message,
          #builtin_event{mfa = {erlang,process_flag,[trap_exit,_]}} = PFlag) ->
  dependent(PFlag, Message);

dependent(#exit_event{}, #exit_event{}) ->
  false;

dependent(#message_event{
             patterns = Patterns,
             recipient = Recipient,
             trapping = Trapping},
          #message_event{
             message = #message{data = Data},
             recipient = Recipient,
             type = Type
            }) ->
  case is_function(Patterns) of
    true -> message_could_match(Patterns, Data, Trapping, Type);
    false -> false
  end;

dependent(#message_event{
             message = #message{data = Data, message_id = Id},
             recipient = Recipient
            },
          #receive_event{
             message = Message,
             patterns = Patterns,
             recipient = Recipient,
             timeout = Timeout
            }) ->
  Timeout =/= infinity
    andalso
    case Message of
      'after' -> Patterns(Data);
      #message{message_id = Id} -> true;
      _ -> false
    end;
dependent(#receive_event{
             message = 'after',
             patterns = Patterns,
             recipient = Recipient,
             trapping = Trapping},
          #message_event{
             message = #message{data = Data},
             recipient = Recipient,
             type = Type
            }) ->
   Patterns(Data) andalso message_could_match(Patterns, Data, Trapping, Type);

dependent(#message_event{}, _EventB) ->
  false;
dependent(_EventA, #message_event{}) ->
  false;

dependent(#receive_event{}, _EventB) ->
  false;
dependent(_EventA, #receive_event{}) ->
  false;

%% XXX: Event may be undefined in a wakeup tree.
dependent(_EventA, _EventB) ->
  ?debug("UNSPECIFIED DEPENDENCY!\n~p\n~p\n", [_EventA, _EventB]),
  true.

%%------------------------------------------------------------------------------

dependent_exit(_Exit, {erlang, '!', [R,_]}) ->
  is_atom(R);
dependent_exit(_Exit, {erlang, process_flag, _}) ->
  false;
dependent_exit(_Exit, {erlang, spawn, _}) ->
  false;
dependent_exit(_Exit, _MFA) ->
  ?debug("UNSPECIFIED EXIT DEPENDENCY!\n~p\n", [_MFA]),
  true.

%%------------------------------------------------------------------------------

dependent_built_in({erlang,'!',_}, {erlang,'!',_}) ->
  false;

dependent_built_in({erlang,'!',_}, {erlang,process_flag,_}) ->
  false;
dependent_built_in({erlang,process_flag,_} = PFlag, {erlang,'!',_} = Send) ->
  dependent_built_in(Send, PFlag);

dependent_built_in({erlang,link,_}, {erlang,process_flag,_}) ->
  false;
dependent_built_in({erlang,process_flag,_} = PFlag, {erlang,link,_} = Link) ->
  dependent_built_in(Link, PFlag);

dependent_built_in({erlang,'!',_}, {erlang,spawn,_}) ->
  false;
dependent_built_in({erlang,spawn,_} = Spawn, {erlang,'!',_} = Send) ->
  dependent_built_in(Send, Spawn);

dependent_built_in({ets,lookup,_}, {ets,lookup,_}) ->
  false;

dependent_built_in({ets,insert,[TableName,_Insert]},
                   {ets,lookup,[TableName,_Lookup]}) ->
  ?debug("INCOMPLETELY SPECIFIED ETS DEPENDENCY!\n", []),
  true;
dependent_built_in({ets,insert,_}, {ets,lookup,_}) ->
  false;
dependent_built_in({ets,lookup,_} = EtsLookup,
                   {ets,insert,_} = EtsInsert) ->
  dependent_built_in(EtsInsert, EtsLookup);

dependent_built_in({erlang,_,_}, {ets,_,_}) ->
  false;
dependent_built_in({ets,_,_} = Ets, {erlang,_,_} = Erlang) ->
  dependent_built_in(Erlang, Ets);

dependent_built_in({M1,_,_} = _MFA1, {M2,_,_} = _MFA2) ->
  ?debug("UNSPECIFIED DEPENDENCY!\n~p\n~p\n", [_MFA1, _MFA2]),
  M1 =:= M2.

%%------------------------------------------------------------------------------

message_could_match(_Patterns, _Data, Trapping, Type) ->
  %% Patterns(Data)
  %%   andalso
  (Trapping orelse (Type =:= message)).