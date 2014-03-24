%% Contains functions -- test/0 -- to test Fischer's mutual exclusion algorithm.

-module(fischer_qc).

-export([test/0]).

-include_lib("eqc/include/eqc.hrl").

%% Fix the maximum number of times to enter the critical region.
-define(NUM_WRITES,20).

fischer_prop() ->
  ?FORALL
     ({NProcs,D,T},
      {pos_nat(),pos_nat(),pos_nat()},
      begin
	try ets:delete(mutex_table) catch _:_ -> ok end,
	io:format("Trying configuration ~p,~p,~p~n",[NProcs,D,T]),
	Result =
	  pulse_time_scheduler:start
	    ([infinitely_fast,
	      {timeParms,[{timeoutJitter,infinity}]},
	      {verbose,false},
	      {eventLog,false}],
	     fun () -> fischer:start(NProcs,D,T,?NUM_WRITES) end),
	case lists:keyfind(live,1,Result) of
	  {live,Pids} ->
	    length(Pids)>0;
	  Other ->
	    io:format
	      ("*** Warning: live pid listing has strange format: ~p~n",
	       [Other]),
	    false
	end
      end).

test() ->
  pulse_time_instrument:c(["examples/fischer"]),
  eqc:quickcheck(?ALWAYS(10,fischer_prop())).

pos_nat() ->
  ?SUCHTHAT(X,nat(),X=/=0).

