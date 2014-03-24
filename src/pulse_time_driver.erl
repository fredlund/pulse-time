%% Copyright (c) 2014, Thomas Arts, Koen Claessen, John Hughes,
%% Michal Palka, Nick Smallbone, Hans Svensson, Lars-Ake Fredlund.
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions are met:
%%     %% Redistributions of source code must retain the above copyright
%%       notice, this list of conditions and the following disclaimer.
%%     %% Redistributions in binary form must reproduce the above copyright
%%       notice, this list of conditions and the following disclaimer in the
%%       documentation and/or other materials provided with the distribution.
%%     %% Neither the name of the copyright holders nor the
%%       names of its contributors may be used to endorse or promote products
%%       derived from this software without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS''
%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
%% BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, 
%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR 
%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF 
%% ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%% @author Thomas Arts, Koen Claessen, John Hughes,
%% Michal Palka, Nick Smallbone, Hans Svensson, Lars-Ake Fredlund
%% @copyright 2009-2014 Thomas Arts, Koen Claessen, John Hughes,
%% Michal Palka, Nick Smallbone, Hans Svensson, Lars-Ake Fredlund
%% @doc
%% @private

-module(pulse_time_driver).
-compile(export_all).

drive(Fun) ->
  drive(Fun,[]).

drive(Fun,Config) ->
  Result = pulse_time_scheduler:start([{seed,now()}|Config],Fun),
  io:format("~p~n",[noEvents(Result)]),
  case lists:keysearch(events,1,Result) of
    {value, {events, Events}} ->
      io:format("(generating file schedule.dot ...)~n"),
      pulse_time_dot:dot("schedule.dot", Events);
     
     _ -> ok
  end,
  Result.

drive0(Fun) ->
  drive(Fun),
  ok.

drive2(Fun) ->
  io:format("=== RUN 1 ===~n"),
  Result1 = drive(Fun),
  Sched1  = case lists:keysearch(schedule,1,Result1) of
              {value, {schedule,Sched}} -> Sched;
              _                         -> exit("no schedule")
            end,
  io:format("=== RUN 2 ===~n"),
  Result2 = pulse_time_scheduler:start([{schedule,Sched1}],fun() -> Fun() end),
  io:format("=== RESULT ===~n"),
  diff(noEvents(Result1),noEvents(Result2)).

noEvents(Result) ->
  [ Res || Res <- Result, case Res of {events,_} -> false; _ -> true end ].

diff(X,X) -> X;

diff(X,Y) when is_tuple(X), is_tuple(Y), size(X) == size(Y) ->
  list_to_tuple(diff(tuple_to_list(X), tuple_to_list(Y)));

diff([X|Xs],[Y|Ys]) ->
  [diff(X,Y)|diff(Xs,Ys)];

diff(X,Y) ->
  {X, 'NEQ', Y}.

