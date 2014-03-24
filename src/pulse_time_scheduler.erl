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

%% @doc This module contains functions for scheduling (running)
%% an Erlang function, implemented on top of the PULSE user scheduler. 
%% A number of parameters controls the behaviour
%% of timeout clauses.
%% @author Thomas Arts, Koen Claessen, John Hughes,
%% Michal Palka, Nick Smallbone, Hans Svensson, Lars-Ake Fredlund
%% @copyright 2009-2014 Thomas Arts, Koen Claessen, John Hughes,
%% Michal Palka, Nick Smallbone, Hans Svensson, Lars-Ake Fredlund

-ifndef(SCHEDULER).
-module(pulse_time_scheduler).
-else.
-module(scheduler_instr).
-endif.

-compile(export_all).

-export([start/2]).

-record(state,
  { actives  = []
  , blocks   = []
  , after0s  = []
  , yields   = []
  , queues   = []
  , now      = 0
  , max_wait_times = []
  , links    = []
  , monitors = []
  , trapping = []
  , names    = []
  , time_parms  = []
  , schedule = random
  , log      = []
  , events   = events
  , verbose  = true
  }).

-type option() :: 'infinitely_fast' | 'infinitely_slow' | 'time_random' 
                | {'quite_slow',integer()} | {'quite_slow_random',integer()}
		| {'timeParms',[time_option()]}
		| {'verbose',boolean()}
                | {'seed',{integer(),integer(),integer()}}
                | {'schedule',any()}
                | {'eventLog',boolean()}.

-type time_option() :: {'timeoutJitter',integer()} 
		     | {'timeoutInterval',integer()}
		     | {'timeoutPrecedence',boolean()}
                     | {'timeIncrement',integer()}.

% ----------------------------------------------------------------
% Translations

% 1.
% spawn(Fun)  --->
%   ?MODULE:spawn(Fun)

% 2.
% Pid ! Msg  --->
%   ?MODULE:send(Pid,Msg)

% 3a.
% receive
%   Pat* -> Expr*
% end
%   --->
%     ?MODULE:receiving(fun(After0) ->
%       receive
%         Pat*    -> Expr*
%         after 0 -> After0()
%       end
%     end)

% 3b.
% receive
%   Pat*    -> Expr*
%   after 0 -> ExprAfter0
% end
%   --->
%     ?MODULE:receivingAfter0(fun(After0) ->
%       receive
%         Pat*    -> Expr*
%         after 0 -> After0()
%       end
%     end,
%     fun() -> ExprAfter0 end)


version() ->
  ?PULSE_TIME_VERSION.

% ----------------------------------------------------------------
% Functions to use for processes

% to be used instead of spawn(Fun)
spawn(Fun) ->
  ?MODULE:spawn(noname,Fun).

spawn(NameHint,Fun) ->
  Pid = erlang:spawn(fun() ->
    receive
      {?MODULE, go} -> Fun()
    end
  end),
  ?MODULE ! {fork, NameHint, Pid},
  Pid.

% to be used instead of spawn_link(Fun)
spawn_link(Fun) ->
  ?MODULE:spawn_link(noname, Fun).

spawn_link(NameHint, Fun) ->
  Pid = ?MODULE:spawn(NameHint, Fun),
  ?MODULE ! {link, Pid},
  Pid.

spawn_link(NameHint,M,F,Args) ->
  ?MODULE:spawn(NameHint,fun () -> apply(M,F,Args) end).

timestamp() ->
  ?MODULE:now().

now() ->
  ?MODULE ! {now},
  receive
    {?MODULE, now, Now} ->
      MicroSeconds = Now rem 1000000,
      Seconds = Now div 1000000,
      MegaSeconds = Seconds div 1000000,
      {MegaSeconds, Seconds rem 1000000, MicroSeconds}
  end.

max_wait_time(T) ->
  MilliSeconds =
    if
      T==infinity -> T;
      true -> T*1000
    end,
  ?MODULE ! {max_wait_time,MilliSeconds}.

% to be used instead of yield()
yield() ->
  ?MODULE ! {yield},
  receive
    {?MODULE, go} -> ok
  end.

% to be used instead of link(Pid)
link(Pid) ->
  ?MODULE:yield(),
  ?MODULE ! {link, Pid},
  ok.

% to be used instead of process_flag
process_flag(Flag,Value) ->
  ?MODULE:yield(),
  case Flag of
      trap_exit -> 
	  ?MODULE ! {trap_exit, Value};
      _ ->
	  ok
  end,
  erlang:process_flag(Flag,Value).

exit(Reason) ->
    erlang:exit(Reason).
exit(undefined, _) ->
    erlang:exit(badarg);
exit(Pid, Reason) when is_atom(Pid) ->
    ?MODULE:exit(whereis(Pid), Reason);
exit(Pid, Reason) ->
    ?MODULE ! {unblock, Pid},
    receive
        {?MODULE, go} ->
            erlang:exit(Pid, Reason)
    end.

monitor(process,Pid) when is_pid(Pid) ->
	?MODULE:yield(),
	Ref = make_ref(),
    ?MODULE ! {monitor,Pid,Ref},
	Ref.

% to be used instead of Pid ! Msg
send(undefined,_Msg) ->
  erlang:exit(badarg);

send(Pid,Msg) when is_atom(Pid) ->
  send(whereis(Pid),Msg);

send(Pid,Msg) ->
  ?MODULE ! {send, Pid, Msg},
  Msg.

% to be used around a receive statement without "after 0"
receiving(Receive) ->
  Receive(fun() ->
    ?MODULE ! {block},
    receive
      {?MODULE, go} -> receiving(Receive)
    end
  end).

% to be used around a receive statement with "after 0"
receivingAfterX(Receive,ExprAfterX,AfterX) ->
  MilliSeconds =
    if
      AfterX==infinity -> AfterX;
      true -> AfterX*1000
    end,
  Receive(fun() ->
    ?MODULE ! {blockAfterX,MilliSeconds},  %% convert to microseconds
    receive
      {?MODULE, afterX} -> receive {?MODULE, go} -> ExprAfterX() end;
      {?MODULE, go}     -> receivingAfterX(Receive,ExprAfterX,AfterX)
    end
  end).

% to be used to make a side-effecting call
side_effect(M,F,Args) ->
    ?MODULE:yield(),
    Res = apply(M,F,Args),
    ?MODULE ! {side_effect,M,F,Args,Res},
    Res.

event(Event) ->
    ?MODULE ! {event, Event}.

% sleep
sleep(Timeout) ->
	receivingAfterX(fun(F) ->
							F()
					end, 
					fun() -> ok end,
					Timeout).

% to start the scheduler

% argument list:
%   - {verbose, Verbose}    verbosity, default: true
%   - {seed, Seed}          random seed to use
%   - {schedule, Schedule}  schedule to use
%   - {eventLog, EventLog}  event logging on/off, default: true

% result list:
%   - {schedule, Schedule}  schedule to be used for replay
%   - {live, Live}          the pids of processes alive when scheduler terminated (Live /= [] means deadlock)
%   - {events, Events}      event log (to be fed to dot:dot/2 for dot-file)

% for an example of the above, see driver:drive0/1.

start(Fun) ->
  start([], Fun).

%% @doc Executing the function argument with the configured parameters.
%%
-spec start(Options::[option()], Fun::fun(() -> any())) -> any().
start(Config,Fun) ->
  erlang:process_flag(trap_exit,true),
  
  case proplists:get_value(infinitely_fast,Config,false) of
    true ->
      InfinitelyFast = [{timeoutInterval,0}];
    _ ->
      InfinitelyFast = []
  end,

  case proplists:get_value(infinitely_slow,Config,false) of
    true ->
      InfinitelySlow = [{timeoutInterval,infinity},{timeoutPrecedence,true}];
    _ ->
      InfinitelySlow = []
  end,

  case proplists:get_value(time_random,Config,false) of
    true ->
      TimeRandom = [{timeoutInterval,infinity},{timeoutPrecedence,false}];
    _ ->
      TimeRandom = []
  end,

  case proplists:get_value(quite_slow,Config) of
    Interval when (Interval==infinity)
		  or is_integer(Interval) ->
      QuiteSlow = [{timeoutInterval,Interval},{timeoutPrecedence,true}];
    _ ->
      QuiteSlow = []
  end,

  case proplists:get_value(quite_slow_random,Config) of
    RandomInterval when (RandomInterval==infinity)
			or is_integer(RandomInterval) ->
      QuiteSlowRandom = [{timeoutInterval,RandomInterval},{timeoutPrecedence,false}];
    _ ->
      QuiteSlowRandom = []
  end,

  % seed
  case lists:keysearch(seed,1,Config) of
    {value, {seed, {A,B,C}}} -> random:seed(A,B,C);
    _                        -> ok
  end,
  
  % schedule
  case lists:keysearch(schedule,1,Config) of
    {value, {schedule, Sched}} -> ok;
    _                          -> Sched = random
  end,

  % verbose
  case lists:keysearch(verbose,1,Config) of
    {value, {verbose, Verbose}} -> ok;
    _                           -> Verbose = true
  end,

  % event logging
  Events = case lists:keysearch(eventLog,1,Config) of
    {value, {eventLog, false}} -> noEventLogging;
    _                          -> erlang:spawn_link(fun() -> collectEvents(Verbose,[]) end)
  end,

  print(Verbose,"Config is ~p~n",[Config]),

  PreTimeParms =
    InfinitelyFast++InfinitelySlow++TimeRandom++QuiteSlow++QuiteSlowRandom,
  case lists:sum
    (lists:map
       (fun (L) -> if L=/=[] -> 1; true -> 0 end end, 
	[InfinitelyFast,InfinitelySlow,TimeRandom,QuiteSlow,QuiteSlowRandom])) of
    N when N=<1 -> ok;
    _ -> 
      io:format
	("*** Error: more than one of the combined parameters (infinitely_slow,...) set~n"),
      io:format("PreTimeParms:~p~n",[PreTimeParms]),
      throw(bad)
  end,

  TimeParms =
    case lists:keysearch(timeParms,1,Config) of
      {value, {timeParms, TP}} -> PreTimeParms++TP  ;
      _ -> PreTimeParms
    end,

  print(Verbose,"Time parms are ~p~n",[TimeParms]),

  register(?MODULE, self()),
  Root = erlang:spawn_link(fun() ->
    receive
      {?MODULE, go} ->
        Result = Fun(),
        erlang:exit({result,Result})
    end
  end),

  %io:format(" -> <root> = ~p\n",[Root]),

  State = #state{ actives  = [Root]
                , names    = [{Root,root}]
                , schedule = Sched
                , verbose  = Verbose
                , events   = Events
		, time_parms = TimeParms
                },
  print(Verbose, "*** scheduler started.~n"),
  Result = schedule(State),
  print(Verbose, "*** scheduler finished.~n"),
  unregister(?MODULE),
  Result.

% ----------------------------------------------------------------
% implementation of the scheduler

% the main scheduler.
schedule(State) ->
  Verbose = State#state.verbose,
  print
    (Verbose,
     "~ns(~s,~s,~s,~s,w=~s,b=~s)~n",
     [print_pids(State#state.actives,State),
      print_pids(lists:map(fun ({{_,Pid},_}) -> Pid end, State#state.queues),State),
      print_afters(State#state.after0s,State),
      print_pids(State#state.yields,State),
      print_afters(State#state.max_wait_times,State),
      print_pids(State#state.blocks,State)]),
  case State#state.actives of
    [Pid|Pids] ->
      print(Verbose,"running active process ~p~n",[name(State,Pid)]),
      Pid ! {?MODULE, go},
      runProcess(Pid,State#state{actives = Pids});
    [] ->
      AnyAliveTimer =
	lists:any
	  (fun ({_,Timer}) -> Timer=/=infinity end,
	   State#state.after0s),
      case {State#state.actives, State#state.queues, AnyAliveTimer, State#state.yields} of
    % all processes are blocked; there are no messages to deliver
	{[],[],false,[]} ->
	  [ {schedule, lists:reverse(State#state.log)}
	  , {live,     State#state.blocks}
	  ]
	    ++ case State#state.events of
		 noEventLogging -> [];
		 Events         -> Events ! {done, self()},
				   receive
				     Log = {events, _} -> [Log]
				   end
	       end;
	
    % choose a process to unblock
	_ ->
       NonTimeoutPids =
	lists:usort([To || {{_,To},_} <- State#state.queues]
		    ++ [Pid || {Pid,N} <- State#state.after0s, N==0]
		    ++ State#state.yields
		   ),

      TimeoutInterval = 
	if
	  NonTimeoutPids==[] ->
	    infinity;
	  true ->
	    timeParmValue(timeoutInterval,State,0)
	end,
	  print(Verbose,"timeoutInterval is ~p~n",[TimeoutInterval]),
      if
	%% Special case which does not require computation timed transitions
	NonTimeoutPids=/=[], TimeoutInterval==0 ->
	  {Pid,State1} = choosePid(State,NonTimeoutPids),
	  print(Verbose,"unblocking non-timeout process ~p~n",[name(State,Pid)]),
	  unblockProcess(Pid,State1);
	true ->
	  TimeoutJitter =
	    timeParmValue(timeoutJitter,State,0),
	  RawTimeouts = 
	    State#state.after0s,
          MaxWaitTime =
     	    max_wait_times
	      (lists:map(fun ({Pid,_}) -> Pid end, RawTimeouts),
	       State),
	  print(Verbose,"MaxWaitTime is ~p~n",[MaxWaitTime]),
	  Timeouts =
	    filter_timeouts
	      (RawTimeouts,TimeoutInterval,TimeoutJitter,MaxWaitTime),
	  TimeoutPrecedence =
	    timeParmValue(timeoutPrecedence,State,false),
	  print
	    (Verbose,
	     "TimeoutInterval=~p TimeoutPrecedence=~p TimeoutJitter=~p~n",
	     [TimeoutInterval,TimeoutPrecedence,TimeoutJitter]),
	  TimeoutPids =
	    lists:map(fun ({Pid,_}) -> Pid end, Timeouts),
	  AllPids = 
	    if
	      TimeoutPrecedence, TimeoutPids=/=[] ->
		lists:map(fun (Pid) -> {timeout,Pid} end, TimeoutPids);
	      true ->
		lists:map(fun (Pid) -> {nontimeout,Pid} end,NonTimeoutPids)++
		  lists:map(fun (Pid) -> {timeout,Pid} end,TimeoutPids)
	    end,
	  {{TransitionType,Pid},State1} = choosePid(State,AllPids),
	  print
	    (Verbose,
	     "Pid=~p Nontimeouts=~s Timeouts=~s~n",
	     [print_pid(Pid,State),
	      print_pids(NonTimeoutPids,State),
	      print_afters(Timeouts,State)]),
	  if
	    TransitionType==timeout ->
	      {value,{_,Timeout}} = lists:keysearch(Pid,1,Timeouts),
	      WaitTime =
		if
		  TimeoutJitter==infinity ->
		    if
		      MaxWaitTime=/=infinity ->
			Range =
			  tadd
			  (tminus(tmax(0,tmax(MaxWaitTime,Timeout)),
				  tmax(0,Timeout)),
			   1),
			max(0,Timeout)+random:uniform(Range);
		      true ->
			Range = 5000,  %% for want of a better alternative
			tadd(tmax(0,Timeout),random:uniform(Range))
		    end;
		  true -> tmax(0,Timeout)
		end,
	      print
		(Verbose,
		 "TimeoutProcess=~p Timeout=~p WaitTime=~p~n",
		 [print_pid(Pid,State),Timeout,WaitTime]),
	      State2 =
		State1#state
		{after0s = [{Pid1,nonzero(tminus(TO,WaitTime))} ||
			     {Pid1,TO} <- RawTimeouts,
			     Pid1=/=Pid]
		, blocks  = State1#state.blocks -- [Pid]
		, now = State1#state.now+WaitTime
		, actives = [Pid]
		, max_wait_times=
		   modify_max_wait_times
		     (WaitTime,
		      lists:keydelete(Pid,1,State1#state.max_wait_times))},
	      event(State,{continue,name(State,Pid)}),
	      Pid ! {?MODULE, afterX},
	      print(Verbose,"unblocking timeout process ~p~n",[name(State,Pid)]),
	      schedule(State2);
	    true ->
	      %% We choose a non-timeout action
	      print(Verbose,"unblocking non-timeout process ~p~n",[name(State,Pid)]),
	      unblockProcess(Pid,State1)
	  end
      end
      end
  end.

print_comma_list(_F,[]) ->
  "";
print_comma_list(F,[Item]) ->
  F(Item);
print_comma_list(F,[Item|Rest]) ->
  F(Item)++","++print_comma_list(F,Rest).

print_after({Pid,Timeout},State) ->
  print_pid(Pid,State)++"@"++io_lib:format("~p",[Timeout]).

print_afters(Afters,State) ->
  "["++print_comma_list(fun (Item) -> print_after(Item,State) end, Afters)++"]".

print_pid(Pid,State) ->
  case name(State,Pid) of
    L when is_list(L) -> L;
    Other -> io_lib:format("~p",[Other])
  end.

print_pids(Pids,State) ->
  "["++print_comma_list(fun (Item) -> print_pid(Item,State) end, Pids)++"]".

print_time(N) ->
  Seconds = N div 1000000,
  Microseconds = N rem 1000000,
  io_lib:format("~p.~p",[Seconds,Microseconds]).

timeParmValue(Parm,State,DefaultValue) ->
  proplists:get_value(Parm,State#state.time_parms,DefaultValue).

chooseTimeout(State,Timeouts) ->
  %% We are breaking schedule, but ok for now
  {choose(Timeouts),State}.

filter_timeouts(RawTimeouts,TimeoutInterval,TimeoutJitter,MaxWaitTime) ->
  SortedTimeouts =
    lists:sort(fun({_,A},{_,B}) -> leq(A,B) end,RawTimeouts),
  case SortedTimeouts of
    [{_,infinity}|_] -> [];
    [FirstTimeout={_,T1}|Rest] ->
      case leq(T1,TimeoutInterval) of
	true ->
	  [FirstTimeout|
	   lists:filter
	     (fun ({_,T2}) ->
		  if
		    T2==infinity -> false;
		    true ->
		      leq(T2,TimeoutInterval)
			andalso leq(T2-max(T1,0),TimeoutJitter)
			andalso leq(T2,MaxWaitTime)
		  end
	      end, Rest)];
	false -> []
      end;
    _ -> []
  end.

leq(T,T) -> true;
leq(infinity,_) -> false;
leq(_,infinity) -> true;
leq(T1,T2) -> T1 =< T2.

nonzero(0) -> -1;
nonzero(N) -> N.

tmin(infinity,T2) -> T2;
tmin(T1,infinity) -> T1;
tmin(T1,T2) -> min(T1,T2).

tmax(infinity,_T2) -> infinity;
tmax(_T1,infinity) -> infinity;
tmax(T1,T2) -> max(T1,T2).

tminus(infinity,_) -> infinity;
tminus(_,infinity) -> throw(badarg);
tminus(T0,T1) -> T0-T1.

tadd(infinity,_) -> infinity;
tadd(_,infinity) -> infinity;
tadd(T0,T1) -> T0+T1.

modify_max_wait_times(AddedTime,WaitTimes) ->
  lists:map(fun ({Pid,Time}) ->
		{Pid,
		 if Time==infinity -> Time; true -> max(Time-AddedTime,0) end}
	    end, WaitTimes).

max_wait_times(Pids,State) ->
  lists:foldl
    (fun (Pid,Limit) -> 
	 case lists:keyfind(Pid,1,State#state.max_wait_times) of
	   {_,T} -> tmin(Limit,T);
	   _ -> Limit
	 end
     end, infinity, Pids).


increment_time(State) ->
  case timeParmValue(timeIncrement,State,0) of
    N when N>0 ->
      Increment = random:uniform(N),
      State#state
	{
	now=State#state.now+Increment
	,after0s =
	  [{Pid1,nonzero(tminus(TO,Increment))} ||
	    {Pid1,TO} <- State#state.after0s]
	,max_wait_times=
	  modify_max_wait_times(Increment,State#state.max_wait_times)
	};
    0 ->
      State
  end.

% runs all active processes
runProcess(Pid,PreState) ->
  State = increment_time(PreState),
  receive
    % fork a new process with a given name
    {fork, NameHint, Pid2} ->
      Name = createName(State#state.names,NameHint,Pid2),
      State1 = State#state{ actives = [Pid2 | State#state.actives]
                          , names   = [{Pid2,Name}|State#state.names]
                          },
      event(State,{fork,name(State1,Pid),name(State1,Pid2),Pid2}),
      erlang:link(Pid2),
      runProcess(Pid,State1);

    % link to a process
    {link, Pid2} when Pid /= Pid2 ->
      event(State,{link,name(State,Pid),name(State,Pid2)}),
      case lists:member(Pid2, State#state.actives ++ State#state.blocks) of
        true  -> runProcess(Pid,State#state{links=[{Pid,Pid2}|State#state.links]});
        false -> event(State,{send,name(State,Pid2),{'EXIT',Pid2,noproc},name(State,Pid)}),
                 runProcess(Pid,State#state{queues = sendOff(Pid2,Pid,{exit,Pid2,noproc},State#state.queues)})
      end;        

    {link, Pid} ->
      event(State,{link,name(State,Pid),name(State,Pid)}),
      runProcess(Pid,State);

    {monitor, Pid2, Ref} when is_pid(Pid2), Pid /= Pid2 ->
	   event(State,{monitor, name(State,Pid), name(State,Pid2),Ref}),
	   case lists:member(Pid2, State#state.actives ++ State#state.blocks) of

		   true  -> runProcess(Pid,
							   State#state{monitors = 
										   [{Pid,Pid2,Ref} | State#state.monitors]}
							  );
		   false -> event(State,{send,name(State,Pid2),
								 {'DOWN',Ref,process,Pid,noproc},
								 name(State,Pid)}),
					runProcess(Pid,
							   State#state{queues = 
										   sendOff(Pid2,Pid,
												   {msg,{'DOWN',Ref,process,Pid2,noproc}},
												   State#state.queues)}
							  )
	   end;

    % process flag
    {trap_exit, Value} ->
      event(State,{trap,name(State,Pid),Value}),
      runProcess(Pid,State#state{trapping = unitIf(Pid,Value) ++ (State#state.trapping -- [Pid])});

    % send a message
    {send, To, Msg} ->
      event(State,{send,name(State,Pid),Msg,name(State,To)}),
      runProcess(Pid,State#state{queues = sendOff(Pid,To,{msg,Msg},State#state.queues)});

    % block (in a receive)
    {block} ->
      event(State,{block,name(State,Pid)}),
      schedule(State#state{blocks = [Pid | State#state.blocks]});

    % fall through to "after 0" (in a receive)
    {blockAfterX,Timeout} ->
      event(State,{afterX,Timeout,name(State,Pid)}),
      schedule(State#state{  after0s = [{Pid,Timeout} | State#state.after0s]
						   , blocks  = [Pid           | State#state.blocks]});

    % now
    {now} ->
      Pid ! {?MODULE,now,State#state.now},
      runProcess(Pid,State);

    % max_wait_time
    {max_wait_time,T} ->
      WaitTimes = lists:keystore(Pid, 1, State#state.max_wait_times, {Pid,T}),
      runProcess(Pid,State#state{max_wait_times=WaitTimes});

    % yield
    {yield} ->
      event(State,{yield,name(State,Pid)}),
      schedule(State#state{  yields = [Pid | State#state.yields]
						   , blocks = [Pid | State#state.blocks]});

    % consuming a message
    {consumed,Who,What} ->
      event(State,{consumed,name(State,Who),What}),
      runProcess(Who,State);
    
    % made a side-effect
    {side_effect,M,F,A,Res} ->
      event(State,{side_effect,name(State,Pid),M,F,A,Res}),
      runProcess(Pid, State);

    {event,Event} ->
      event(State, Event),
      runProcess(Pid, State);

    {unblock, Pid2} ->
      case {lists:member(Pid2, State#state.blocks),
            lists:member(Pid2, State#state.yields),
            lists:member(Pid2, State#state.after0s)} of
          {true, false, false} ->
              NewState = State#state { blocks = State#state.blocks -- [Pid2],
                                       actives = [Pid2|State#state.actives] };
          _ ->
              NewState = State
      end,
      Pid ! {?MODULE, go},
      runProcess(Pid, NewState);

    % finish
    {'EXIT',Pid,Reason} ->
      event(State,{exit,name(State,Pid),Reason}),
	  LinksToSend = 
			  lists:usort( 
				[ {exit,Pid1} || {Pid1,Pid2} <- State#state.links, Pid2 == Pid ] ++
				[ {exit,Pid2} || {Pid1,Pid2} <- State#state.links, Pid1 == Pid ]),
	  MonitorsToSend = 
			  lists:usort(
				[{mon,Pid1,Ref} || {Pid1,Pid2,Ref} <- State#state.monitors, 
								   Pid2 == Pid]),

      schedule(State#state
        { links  = [ {Pid1,Pid2}
                  || {Pid1,Pid2} <- State#state.links
                   , Pid /= Pid1
                   , Pid /= Pid2
                   ]
		, queues = lists:foldl(
					 fun({exit,Pid1},Queues) ->
							 event(State,{send,name(State,Pid),
										  {'EXIT',Pid,Reason},name(State,Pid1)}),
							 sendOff(Pid,Pid1,{exit,Pid,Reason},Queues);
						({mon,Pid1,Ref},Queues) ->
							 event(State,{send,name(State,Pid),
										  {'DOWN',Ref,process,Pid,Reason},name(State,Pid1)}),
							 sendOff(Pid,Pid1,{msg,{'DOWN',Ref,process,Pid,Reason}},Queues)
					 end
					 , [ Queue || Queue = {{_,To},_} <- State#state.queues
								  , To /= Pid ]
					 , LinksToSend ++ MonitorsToSend)							 
        , after0s = [ T    || T = {Pid1,_} <- State#state.after0s, Pid1 /= Pid ]
        , blocks  = [ Pid1 || Pid1 <- State#state.blocks,  Pid1 /= Pid ]
        }
      )
  end.

% adding a message to a queue
sendOff(From,To,Msg,Queues) ->
  case lists:keysearch({From,To},1,Queues) of
    {value, {_,Queue}} ->
      lists:keyreplace({From,To},1,Queues,{{From,To},Queue++[Msg]});
    
    false ->
      [{{From,To},[Msg]}|Queues]
  end.

% unblock a process
unblockProcess(Pid,State) ->
  {Action,State1} =
    chooseAction( State,
                  case lists:member(Pid,State#state.yields) of
                    true  -> [yield];
                    false -> [{deliver,From} || {{From,Pid1},_} <- State#state.queues, Pid == Pid1]
                          ++ [afterX || {Pid1,0} <- State#state.after0s, Pid == Pid1]
										
                  end
                ),
  State2 = State1#state{ blocks  = State1#state.blocks   -- [Pid]
                       , after0s = [T || T = {Pid1,_} <- State1#state.after0s, Pid /= Pid1]
                       , yields  = State1#state.yields   -- [Pid]
                       , actives = [Pid || lists:member(Pid,State1#state.blocks)]
                                ++ (State1#state.actives -- [Pid])
                       , log     = [ { name(State1,Pid)
                                     , case Action of
                                         {deliver,From1} -> {deliver,name(State1,From1)};
                                         _               -> Action
                                       end
                                     }
                                   | State1#state.log
                                   ]
                       },
  case Action of
    % deliver a message from a queue
    {deliver,From} ->
      {value, {_,[Msg|Queue]}} = lists:keysearch({From,Pid},1,State2#state.queues),
      case Msg of
        {exit,Who,Reason} ->
          Msg1 = {'EXIT',Who,Reason},
          event(State,{deliver,name(State2,Pid),Msg1,name(State2,From)}),
          case lists:member(Pid,State#state.trapping) of
            false when Reason /= normal ->
              erlang:exit(Pid,Reason);
            
            true -> 
              Pid ! Msg1;

            % Pid is not trapping exits and Reason is normal
            _ ->
              ok
          end;
        
        {msg,Msg0} ->
          event(State,{deliver,name(State2,Pid),Msg0,name(State2,From)}),
          Pid ! Msg0
      end,
      Queues = case Queue of
                 [] ->
                   lists:keydelete({From,Pid},1,State2#state.queues);
                 
                 _ ->
                   lists:keyreplace({From,Pid},1,State2#state.queues,{{From,Pid},Queue})
               end,
      schedule(State2#state{queues = Queues});
    
    % trigger the "after 0"
    afterX ->
      event(State,{continue,name(State2,Pid)}),
      Pid ! {?MODULE, afterX},
      schedule(State2);

    % restart the yielded process
    yield ->
      event(State,{continue,name(State2,Pid)}),
      schedule(State2)
  end.

% create the name
createName(Names,NameHint,Pid) ->
  hd ( [ Name
      || Name <- [NameHint]
              ++ [ case is_atom(NameHint) of
                     true  -> list_to_atom(atom_to_list(NameHint) ++ integer_to_list(N));
                     false -> {NameHint,N}
                   end
                || N <- lists:seq(1,99)
                 ]
              ++ [ {NameHint,Pid} ]
       , not lists:member(Name, [ Name1 || {_,Name1} <- Names ])
       ] ).

% ----------------------------------------------------------------
% helper functions

choose(Xs) ->
  K = random:uniform(length(Xs)),
  lists:nth(K,Xs).

choosePid(State,Pids) ->
  case State#state.schedule of
    [{Name,_}|_] -> {pid(State,Name),State};
    _            -> {choose(Pids),State}
  end.

chooseAction(State,Actions) ->
  case State#state.schedule of
    [{_,Action}|Sched] -> { case Action of
                              {deliver,Name} -> {deliver,pid(State,Name)};
                              _              -> Action
                            end
                          , State#state{schedule=Sched}
                          };
    _                  -> {choose(Actions),State}
  end.

name(State,Pid) ->
  case lists:keysearch(Pid,1,State#state.names) of
    {value,{_,Name}} -> Name;
    _                -> Pid
  end.

pid(State,Name) ->
  case lists:keysearch(Name,2,State#state.names) of
    {value,{Pid,_}} -> Pid;
    _               -> erlang:exit({bad_name,Name})
  end.

unitIf(X,true) -> [X];
unitIf(_,_)    -> [].

% ----------------------------------------------------------------
% collecting / printing events

consumed(What) ->
    ?MODULE ! {consumed,self(),What}.

event(State, Event) ->
  case State#state.verbose of
    Verbose = true ->
      print(Verbose,"time ~s: ",[print_time(State#state.now)]),
      case Event of
        {fork, Name1, Name2, Pid} ->
          print(Verbose, " -> <~p> forks <~p> = ~p.~n", [Name1,Name2,Pid]);

        {link, Name1, Name2} ->
          print(Verbose, " -> <~p> links to <~p>.~n", [Name1,Name2]);

        {monitor, Name1, Name2, Ref} ->
          print(Verbose, " -> <~p> monitors <~p> (Ref: ~p).~n", [Name1,Name2,Ref]);

        {trap, Name, Value} ->
          print(Verbose, " -> <~p> traps exit messages: ~p.~n", [Name,Value]);
        
        {send, Name1, Msg, Name2} ->
          print(Verbose, " -> <~p> sends '~p' to <~p>.~n", [Name1,Msg,Name2]);
        
        {block, Name} ->
          print(Verbose, " -> <~p> blocks.~n", [Name]);
        
        %% {after0, Name} ->
        %%   print(Verbose, " -> <~p> hits an after 0.~n", [Name]);

        {afterX, Timeout, Name} ->
          print(Verbose, " -> <~p> hits an after ~p.~n", [Name,Timeout]);
        
        {yield, Name} ->
          print(Verbose, " -> <~p> yields.~n", [Name]);
        
        {consumed, Name, What} ->
          print(Verbose, " -> <~p> consumed '~p'~n",[Name,What]);
        
        {exit, Name, Reason} ->
          print(Verbose, " -> <~p> exits with '~p'.~n", [Name,Reason]);

        {deliver, Name1, Msg, Name2} ->
          print(Verbose, "*** unblocking <~p> by delivering '~p' sent by <~p>.~n", [Name1,Msg,Name2]);

        {continue, Name} ->
          print(Verbose, "*** unblocking <~p> by continuing from afterX/yield.~n", [Name]);
  
        {side_effect,Name,M,F,A,Res} ->
          print(Verbose, " -> <~p> calls ~p:~p ~p returning ~p.~n", [Name,M,F,A,Res]);
        
        _ ->
          io:format("UNKNOWN EVENT: ~p.~n", [Event])
      end;
   
    _ -> ok
  end,
  
  case State#state.events of
    noEventLogging -> ok;
    Events         -> Events ! Event
  end.

collectEvents(Verbose,Events) ->
  receive
    {done, Pid} -> Pid ! {events,lists:reverse(Events)};
    Event       -> collectEvents(Verbose,[cleanup(Event)|Events])
  end.

cleanup({fork,Name1,Name2,_}) -> {fork,Name1,Name2};
cleanup(Event)                -> Event.

print(Verbose,S) ->
  print(Verbose, S, []).

print(false,_,_) ->
  ok;

print(_,S,Xs) ->
  case ?MODULE of
    pulse_time_scheduler -> io:format(S,Xs);
    _         -> io:format("  (~p) " ++ S,[?MODULE|Xs])
  end.

% ----------------------------------------------------------------
% instrumentation information

'after'() ->
    0.

instrumented() ->
    [{erlang, spawn, [name]},
     {erlang, spawn_link, [name]},
     {erlang, link, []},
     {erlang, process_flag, [yield]},
     {erlang, yield, []},
     {erlang, now, [yield]},
     {os, timestamp, [yield]},
     {erlang, is_process_alive, [dont_capture, yield]},
     {erlang, demonitor, [dont_capture, yield]},
     {erlang, monitor, []},
     {erlang, exit, [yield]},
     {erlang, is_process_alive, [dont_capture,yield]},
	 {timer, sleep, []},
     {io, format, [dont_capture]},
     {ets, lookup, [dont_capture, yield]},
     {ets, insert, [dont_capture, yield]},
     {ets, insert_new, [dont_capture, yield]},
     {ets, delete_object, [dont_capture, yield]},
     {ets, delete, [dont_capture, yield]},
     {ets, delete_all_objects, [dont_capture, yield]},
     {ets, select_delete, [dont_capture, yield]},
     {ets, match_delete, [dont_capture, yield]},
     {ets, match_object, [dont_capture, yield]},
     {ets, new, [dont_capture, yield]},
     {file, write_file, [dont_capture, yield]},

     {supervisor, start_link, [{replace_with, mce_erl_supervisor, start_link}]},
     {supervisor, start_child, [{replace_with, mce_erl_supervisor, start_child}]},
     {supervisor, which_children, [{replace_with, mce_erl_supervisor, which_children}]},

     {gen_event, start_link, [{replace_with, mce_erl_gen_event, start_link}]},
     {gen_event, send, [{replace_with, mce_erl_gen_event, send}]},
     {gen_event, add_handler, [{replace_with, mce_erl_gen_event, add_handler}]},
     {gen_event, notify, [{replace_with, mce_erl_gen_event, notify}]},

     {gen_fsm, start_link, [{replace_with, mce_erl_gen_fsm, start_link}]},
     {gen_fsm, send_event, [{replace_with, mce_erl_gen_fsm, send_event}]},
     {gen_fsm, send_all_state_event, [{replace_with, mce_erl_gen_fsm, send_all_state_event}]},     {gen_fsm, sync_send_all_state_event, [{replace_with, mce_erl_gen_fsm, sync_send_all_state_event}]},

     {gen_server, start_link, [{replace_with, mce_erl_gen_server, start_link}]},
     {gen_server, start, [{replace_with, mce_erl_gen_server, start}]},
     {gen_server, call, [{replace_with, mce_erl_gen_server, call}]},
     {gen_server, cast, [{replace_with, mce_erl_gen_server, cast}]},
     {gen_server, server, [{replace_with, mce_erl_gen_server, server}]},
     {gen_server, loop, [{replace_with, mce_erl_gen_server, loop}]}].

% ----------------------------------------------------------------
