%% An implementation of Fischer's mutual exclusion algorithm in Erlang.

-module(fischer).
-compile(export_all).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Algorithm code

start(N,D,T) ->
  start(N,D,T,infinity).

start(N,D,T,MB) ->
  ets:new(mutex_table,[named_table,public]),
  ets:insert(mutex_table,{variable,0}),
  lists:foreach
    (fun (Id) -> spawn_link(fun () -> idle(Id,D,T,MB) end) end,
     lists:seq(1,N)),
  receive X -> X end.

idle(Id,D,T,MB) ->
  case read() of
    0 -> set(Id,D,T,MB);
    _ -> sleep(1), idle(Id,D,T,MB)
  end.

set(Id,D,T,MB) ->
  max_sleep(1,D),
  setting(Id,D,T,MB).

setting(Id,D,T,MB) ->
  write(Id),
  sleep(T),
  testing(Id,D,T,MB).

testing(Id,D,T,MB) ->
  case read() of
    Id -> mutex(Id,D,T,MB);
    _ -> idle(Id,D,T,MB)
  end.
  
mutex(Id,D,T,MB) ->
  ets:insert(mutex_table,{mutex,{enter,Id}}),
  sleep(1),
  case ets:lookup(mutex_table,mutex) of
    [{mutex,{enter,Id}}] -> ok;
    Other ->
      io:format
	("*** Error: mutex should be held by ~p but status is ~p~n",
	 [Id,Other]),
      throw(bad)
  end,
  write(0), 
  ets:insert(mutex_table,{mutex,void}),
  if
    MB>1 -> idle(Id,D,T,MB-1);
    true -> ok
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Support code

sleep(Milliseconds) ->
  receive
  after Milliseconds -> ok
  end.

max_sleep(SleepMin,SleepMax) ->
  pulse_time_scheduler:max_wait_time(SleepMax),
  receive
  after SleepMin -> ok
  end.

read() ->
  [{variable,Value}] = ets:lookup(mutex_table,variable),
  Value.

write(Value) ->
  ets:insert(mutex_table,{variable,Value}).
		
	  
  

 
