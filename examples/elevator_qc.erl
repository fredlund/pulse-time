%% Contains functions -- test/0 -- for runnning the elevator example

-module(elevator_qc).

-export([test/0]).

-include_lib("eqc/include/eqc.hrl").

elevator_prop(Parms) ->
  io:format("~n~n***********************~nParms are ~p~n",[Parms]),
  ?FORALL
     ({NumFloors,NumElevators},
      {pos_nat(),pos_nat()},
      ?FORALL
	 (InitFloor,eqc_gen:choose(1,NumFloors),
      begin
	io:format
	  ("Trying configuration ~p,~p,~p~n",
	   [InitFloor,NumFloors,NumElevators]),
	Result =
	  pulse_time_scheduler:start
	    (Parms,
	     fun () -> start:start(InitFloor,NumFloors,NumElevators) end),
	case lists:keyfind(events,1,Result) of
	  {events,Events} ->
	    lists:all
	      (fun (Event) ->
		   case Event of
		     {exit,_Pid,{result,_}} -> true;
		     {exit,_Pid,normal} -> true;
		     {exit,Pid,Reason} ->
		       io:format
			 ("~p: failing exit event~n~p~nfound~n",
			  [Pid,Reason]),
		       case
			 safe_filename("bad_schedule_"++atom_to_list(?MODULE),"dot") of
			 {ok,FileName} -> pulse_time_dot:dot(FileName,Events);
			 _ -> ok
		       end,
		       false;
		     _ ->
		       case
			 safe_filename1("good_schedule_"++atom_to_list(?MODULE),48,"dot") of 
			 {ok,FileName} -> pulse_time_dot:dot(FileName,Events);
			 _ -> ok
		       end,
		       true
		   end
	       end, Events);
	  Other ->
	    io:format
	      ("*** Warning: events listing has strange format: ~p~n",
	       [Other]),
	    false
	end
      end)).

test() ->
  pulse_time_instrument:c
    (["examples/lift/start","examples/lift/display",
      "examples/lift/e_graphic","examples/lift/elevator",
      "examples/lift/elevators",
      "examples/lift/elev_sup","examples/lift/g_sup",
      "examples/lift/lift_scheduler",
      "examples/lift/sim_sup","examples/lift/stoplist",
      "examples/lift/sys_event","examples/lift/system_sup",
      "examples/lift/tracer","examples/lift/util",
      "examples/lift/mce_erl_gen_event","examples/lift/mce_erl_supervisor",
      "examples/lift/mce_erl_gen_server", "examples/lift/mce_erl_gen_fsm"]),
  check().

safe_filename(Name,Suffix) ->
  FileName = Name++"."++Suffix,
  case file_exists(FileName) of
    true ->
      safe_filename1(Name,0,Suffix);
    false ->
      {ok,FileName}
  end.

safe_filename1(Name,N,Suffix) when N<50 ->
  FileName = Name++"_"++integer_to_list(N)++"."++Suffix,
  case file_exists(FileName) of
    true ->
      safe_filename1(Name,N+1,Suffix);
    false ->
      {ok,FileName}
  end;
safe_filename1(_,_,_) ->
  error.

file_exists(File) ->
  case file:read_file_info(File) of
    {ok, _} ->
      true;
    {error,enoent} ->
      false
  end.

check() ->
  BaseProps = [{eventLog,true}],
  eqc:quickcheck
    (eqc:on_test
       (fun teardown/2,
	elevator_prop([infinitely_fast|BaseProps]))),

  eqc:quickcheck
    (eqc:on_test
       (fun teardown/2,
	elevator_prop([time_random|BaseProps]))),

  eqc:quickcheck
    (eqc:on_test
       (fun teardown/2,
	elevator_prop([infinitely_slow|BaseProps]))),

  eqc:quickcheck
    (eqc:on_test
       (fun teardown/2,
	elevator_prop([{quite_slow,5000},
		       {timeParms,[{timeIncrement,50}]}|BaseProps]))),

  eqc:quickcheck
    (eqc:on_test
       (fun teardown/2,
	elevator_prop([{quite_slow,250},
		       {timeParms,[{timeIncrement,5}]}|BaseProps]))).
 
teardown(_,_) ->
  lists:foreach
    (fun safe_unregister/1,
     [sim_sup,g_sup,system_sup,lift_scheduler,sys_event,elev_sup]).

safe_unregister(Name) ->
  try unregister(Name) catch _:_ -> ok end.

pos_nat() ->
  ?SUCHTHAT(X,nat(),X=/=0).
