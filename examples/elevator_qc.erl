%% Contains functions -- test/0 -- for runnning the elevator example

-module(elevator_qc).

-export([test/0,run_test/0,check1/1,checkN/3,remotecheck/1,remoteecheck/2,checkt/1]).

-include_lib("eqc/include/eqc.hrl").

%%-define(debug,true).

-ifdef(debug).
-define(LOG(X,Y), io:format("{~p,~p}: ~s~n", [?MODULE,?LINE,io_lib:format(X,Y)])).
-else.
-define(LOG(X,Y), true).
-endif.

%% booting_prop(Parms) ->
%%   io:format
%%     ("~n~n***********************~nParms are ~p~n",
%%      [Parms]),
%%   ?FORALL
%%      ({NumFloors,NumElevators},
%%       {pos_nat(),pos_nat()},
%%       ?FORALL
%% 	 (InitFloor,eqc_gen:choose(1,NumFloors),
%% 	  begin
%% 	    io:format
%% 	      ("Trying configuration ~p,~p,~p~n",
%% 	       [InitFloor,NumFloors,NumElevators]),
%% 	    io:format("stopping gs~n"),
%% 	    catch gs:stop(),
%% 	    timer:sleep(100),
%% 	    io:format("starting gs~n"),
%% 	    gs:start(),
%% 	    io:format("gs started~n"),
%% 	    Self = self(),
%% 	    io:format("starting pulse_time~n"),
%% 	    {Result,Events} =
%% 	      no_failing_processes
%% 		(Parms,
%% 		 fun () ->
%% 		     start:start(InitFloor,NumFloors,NumElevators)
%% 		 end),
%% 	    timer:sleep(100),
%% 	    Result
%% 	  end)).

elevator_prop(Parms) ->
  ?FORALL
    (Cmds,
     eqc_statem:commands(elevator_model),
     begin
       ?LOG("will run~n~p~n",[Cmds]),
       Result =
	 pulse_time_scheduler:start
	   (Parms,
	    fun () -> eqc_statem:run_commands(elevator_model,Cmds) end),
       {Status,Events} = no_failing_processes(Result,Parms),
       {ok,M} = jsg_store:get(total),
       jsg_store:put(total,M+1),
       if
	 not(Status) ->
	   case jsg_store:get(until_bug) of
	     {ok,{found,_}} -> ok;
	     {ok,N} -> jsg_store:put(until_bug,{found,N+1})
	   end,
	   ?LOG("failed. Searching for statem result~n",[]),
	   case find_statem_result(Events) of
	     StatemResult={_,_,R} when R=/=ok ->
	       %%io:format("~p~n",[StatemResult]),
	       eqc_statem:pretty_commands(elevator_model,Cmds,StatemResult,elevator_prop(Parms));
	     _ -> ?LOG("not found~n",[]), ok
	   end;
	 true ->
	   case jsg_store:get(until_bug) of
	     {ok,{found,_}} -> ok;
	     {ok,N} -> jsg_store:put(until_bug,N+1)
	   end,
	   ok
       end,
       Status
     end).
     
find_statem_result([]) ->
  false;
find_statem_result([Event|Rest]) ->
  case Event of
    {exit,_Pid,{result,Result={_H,_DS,_Result}}} -> 
      Result;
    _ ->
      find_statem_result(Rest)
  end.

run_test() ->
  instrument_lift(),

  BaseProps = 
    [
     {eventLog,true}
    ,{verbose,true}
    ],

  Parms =
    [
     {quite_slow,250},
     {timeParms,[{timeIncrement,5}]}
     |BaseProps
    ],

  Commands =
    [
     {set,{var,1},{call,elevator_model,boot,[3,5,5]}},
     {set,{var,2},{call,elevator_model,floor_button_press,[1]}},
     {set,{var,3},{call,elevator_model,floor_button_press,[4]}}
    ],
  
  Result =
    pulse_time_scheduler:start
      (Parms,
       fun () -> eqc_statem:run_commands(elevator_model,Commands) end),

  {Status,_Events} = no_failing_processes(Result,Parms),
  Status.


no_failing_processes(ResultStructure,Parms) ->
  case lists:keyfind(events,1,ResultStructure) of
    {events,Events} ->
      {lists:all
	 (fun (Event) ->
	      case Event of
		{exit,_Pid,{result,{_H,_DS,Result}}} -> 
		  if
		    Result=/=ok ->
		      store_bug(Result),
		      io:format
			("failing due to result:~n~p~n",
			 [Result]);
		    true ->
		      ok
		  end,
		  Result == ok;
		{exit,_Pid,normal} ->
		    true;
		{exit,Pid,Reason} ->
		  store_bug(Event),
		  io:format
		    ("~p: failing exit event~n~p~nfound for parms ~p~n",
		     [Pid,Reason,Parms]),
		  case
		    safe_filename
		    ("bad_schedule_"++atom_to_list(?MODULE),"dot") of
		    {ok,FileName} -> pulse_time_dot:dot(FileName,Events);
		    _ -> ok
		  end,
		  false;
		_ ->
		  case
		    safe_filename1
		    ("good_schedule_"++atom_to_list(?MODULE),48,"dot") of 
		    {ok,FileName} -> pulse_time_dot:dot(FileName,Events);
		    _ -> ok
		  end,
		  true
	      end
	  end, Events), Events};
    Other ->
      io:format
	("*** Warning: events listing has strange format: ~p~n",
	 [Other]),
      {false,[]}
  end.

instrument_lift() ->
  case code:which(stoplist) of
    non_existing ->
      pulse_time_instrument:c
	(["examples/lift/start","examples/lift/display",
	  "examples/lift/e_graphic","examples/lift/elevator",
	  "examples/lift/elevators",
	  "examples/lift/elev_sup","examples/lift/g_sup",
	  "examples/lift/lift_scheduler",
	  "examples/lift/sim_sup","examples/lift/stoplist",
	  "examples/lift/sys_event","examples/lift/system_sup",
	  "examples/lift/tracer","examples/lift/util",
	  "examples/lift/elevator_model",
	  "examples/lift/mce_erl_gen_event","examples/lift/mce_erl_supervisor",
	  "examples/lift/mce_erl_timer",
	  "examples/lift/mce_erl_gen_server", "examples/lift/mce_erl_gen_fsm"]);
    _ ->
      ok
  end.

test() ->
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

baseprops() ->
  [
   {eventLog,true}
   ,{verbose,false}
  ].

store_bug(Bug) ->
  jsg_store:put(bug,Bug).

get_last_bug() ->
  {ok,Result} = jsg_store:get(bug),
  Result.

check_it(N,Props) ->
  instrument_lift(),
  io:format("running test ~p with parms ~p~n",[N,Props]),
  {Time,Value} =
    timer:tc
      (fun () ->
	   eqc:quickcheck
	     (?WHENFAIL(begin io:format("FAILING...~n") end,
			eqc:on_test
			  (fun teardown/2,
			   elevator_prop(Props))))
   end),
  Until = 
    case jsg_store:get(until_bug) of
      {ok,{found,L}} -> L;
      _ -> 0
    end,
  {ok,Total} = jsg_store:get(total),
  PropList = 
    [{until_bug, Until},
     {total, Total},
     {time, Time div 1000000}]++
    if
      Value ->
	[];
      true ->
	Bug = get_last_bug(),
	[{bug,Bug}]
    end,
  {Value,PropList}.

check() ->
  lists:foreach(fun (N) -> check1(N) end, [1,15,2,3,4,5,6]).

remotecheck(N) ->
  {ok,Node,Port} = nodes:startObservedNode(void),
  spawn(Node,elevator_qc,remoteecheck,[N,self()]),
  remoteloop(Node,Port).

remoteloop(Node,Port) ->
  receive
    {result,Result} -> 
      io:format("got result ~p~n",[Result]),
      spawn(Node,erlang,halt,[]),
      Result;
    Message ->
      io:format("got message ~p~n",[Message]),
      remoteloop(Node,Port)
  end.

remoteecheck(N,RemotePid) ->
  jsg_store:put(until_bug,0),
  jsg_store:put(total,0),
  Result = check1b(N),
  RemotePid!{result,Result}.

check1(N) ->
  jsg_store:put(until_bug,0),
  jsg_store:put(total,0),
  check1b(N).

checkt(T) ->
  jsg_store:put(until_bug,0),
  jsg_store:put(total,0),
  check1d(T).

check1d(T) ->
  Props =
    [{quite_slow,T},{timeParms,[{really_wait,false},{timeIncrement,50}]}|baseprops()],
  check_it(52,Props).

checkN(NumTests,N,Remote) ->
  Results =
    lists:map
      (fun (_) ->
	   jsg_store:put(until_bug,0),
	   jsg_store:put(total,0),
	   Result =
	   if
	     Remote -> remotecheck(N);
	     true -> check1b(N)
	   end,
	   io:format("check1 returns ~p~n",[Result]),
	   Result
       end, lists:seq(1,NumTests)),
  Bugs =
    lists:foldl
      (fun ({Value,PropList},Acc) ->
	   if
	     Value -> Acc;
	     true -> [PropList|Acc]
	   end
       end,
       [], Results),
  SortedBugs =
    lists:foldl
      (fun (PropList,Acc) ->
	   Bug = proplists:get_value(bug,PropList),
	   case lists:keyfind(Bug,1,Acc) of
	     false ->
	       [{Bug,[PropList]}|Acc];
	     {_,PropLists} ->
	       lists:keyreplace(Bug,1,Acc,{Bug,[PropList|PropLists]})
	   end
       end, [], Bugs),
  io:format
    ("~p tests: number of bugs found ~p~n",
     [NumTests,
      length(Bugs)]),
  lists:foreach
    (fun ({Bug,PropLists}) ->
	 io:format
	   ("Bug ~p:~n",
	    [Bug]),
	 io:format("PropLists=~p~n",[PropLists]),
	 io:format
	   ("average number of tests until bug found: ~p~n",
	    [average
	       (fun (PropList) -> proplists:get_value(until_bug,PropList) end,
		PropLists)]),
	 io:format
	   ("average number of total tests: ~p~n",
	    [average
	       (fun (PropList) -> proplists:get_value(total,PropList) end,
		PropLists)]),
	 io:format
	   ("average time (for finding bug): ~p~n",
	    [average
	       (fun (PropList) -> proplists:get_value(time,PropList) end,
		PropLists)])
     end, SortedBugs).

average(F,L) ->
  lists:sum(lists:map(F,L)) div length(L).

check1b(N=1) ->
  Props =
    [{quite_slow,250},{timeParms,[{timeIncrement,5}]}|baseprops()],
  check_it(N,Props);

check1b(N=15) ->
  Props =
    [{quite_slow,250},
     {timeParms,[{timeIncrement,5},{really_wait,false}]}|baseprops()],
  check_it(N,Props);

check1b(N=2) ->
  Props =
    [time_random,{timeParms,[{really_wait,false}]}|baseprops()],
  check_it(N,Props);

check1b(N=3) ->
  Props =
    [infinitely_fast,{timeParms,[{really_wait,false}]}|baseprops()],
  check_it(N,Props);

check1b(N=4) ->
  Props =
    [infinitely_slow,{timeParms,[{really_wait,false}]}|baseprops()],
  check_it(N,Props);

check1b(N=5) ->
  Props =
    [{quite_slow,5000},{timeParms,[{really_wait,false},{timeIncrement,50}]}|baseprops()],
  check_it(N,Props);

check1b(N=51) ->
  Props =
    [{quite_slow,500000},{timeParms,[{really_wait,false},{timeIncrement,50}]}|baseprops()],
  check_it(N,Props);

check1b(N=52) ->
  Props =
    [{quite_slow,50000},{timeParms,[{really_wait,false},{timeIncrement,50}]}|baseprops()],
  check_it(N,Props);

check1b(N=6) ->
  Props =
    [{quite_slow,250},{timeParms,[{really_wait,false},{timeIncrement,5}]}|baseprops()],
  check_it(N,Props);

check1b(N=61) ->
  Props =
    [{quite_slow,1},{timeParms,[{really_wait,false},{timeIncrement,5}]}|baseprops()],
  check_it(N,Props).
 
teardown(_,_) ->
  lists:foreach
    (fun safe_unregister/1,
     [sim_sup,g_sup,system_sup,lift_scheduler,sys_event,elev_sup]).

safe_unregister(Name) ->
  try unregister(Name) catch _:_ -> ok end.

