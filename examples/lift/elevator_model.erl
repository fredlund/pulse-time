-module(elevator_model).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-record(state,{n_floors,n_elevators,started=false,elevators}).
-record(elevator,{id}).

-compile(export_all).


initial_state() ->
  #state{}.

boot_pre(State) ->
  not(State#state.started).
boot_args(_State) ->
  ?LET
     ({NumFloors,NumElevators},
      {pos_nat(),pos_nat()},
      [eqc_gen:choose(1,NumFloors),NumFloors,NumElevators]).
boot_next(State,_,[_InitFloor,NumFloors,NumElevators]) ->
  Elevators = 
    lists:map
      (fun (N) -> {N,#elevator{id=N}} end,
       lists:seq(1,NumElevators)),
    State#state
    {started=true,
     n_floors=NumFloors,
     n_elevators=NumElevators,
     elevators=Elevators}.
boot(InitFloor,NumFloors,NumElevators) ->
  io:format("stopping gs~n"),
  catch gs:stop(),
  timer:sleep(1000),
  apply(timer,sleep,[200]),
  io:format("starting gs~n"),
  gs:start(),
  timer:sleep(200),
  io:format("started gs~n"),
  probe:reset(),
  start:start(InitFloor,NumFloors,NumElevators),
  timer:sleep(200),
  gen_event:add_handler(sys_event, ?MODULE, void).

floor_button_press_pre(State) ->
  State#state.started.
floor_button_press_pre(State,[Floor]) ->
  State#state.started andalso (Floor =< State#state.n_floors).
floor_button_press_args(State) ->
  [eqc_gen:choose(1,State#state.n_floors)].
floor_button_press(Floor) ->
  timer:sleep(1000),
  probe:add_event({f_button,Floor}),
  lift_scheduler:f_button_pressed(Floor).
floor_button_press_post(_,_,_) ->
  postcommon().

elevator_button_press_pre(State) ->
  State#state.started.
elevator_button_press_pre(State,[Elevator,Floor]) ->
  State#state.started
    andalso (Elevator =< State#state.n_elevators)
    andalso (Floor =< State#state.n_floors).
elevator_button_press_args(State) ->
  [eqc_gen:choose(1,State#state.n_elevators),
   eqc_gen:choose(1,State#state.n_floors)].
elevator_button_press(Elevator,Floor) ->
  timer:sleep(1000),
  probe:add_event({e_button,Elevator,Floor}),
  lift_scheduler:e_button_pressed(Elevator,Floor).
elevator_button_press_post(_,_,_) ->
  postcommon().
  
postcommon() ->
  Events = probe:events(),
  Stopped = 
    lists:filter
      (fun (Event) ->
	   case Event of
	     {stopped_at,_,_} -> true;
	     _ -> false
	   end
       end, Events),
  StopOrders = 
    lists:filter
      (fun (Event) ->
	   case Event of
	     {e_button,_,_} -> true;
	     {f_button,_} -> true;
	     _ -> false
	   end
       end,
       Events),
  Result = 
    lists:all
      (fun ({stopped_at,Elevator,Floor}) ->
	   lists:any
	     (fun (Event) ->
		  case Event of
		    {f_button,Floor} -> true;
		    {e_button,Elevator,Floor} -> true;
		    _ -> false
		  end
	      end, StopOrders)
       end, Stopped),
  if 
    not(Result) ->
      io:format
	("stopping without stopping order~nstops=~p~norders=~p~n",
	 [Stopped,StopOrders]);
    true ->
      ok
  end,
  Result.

pos_nat() ->
  ?SUCHTHAT(X,nat(),X=/=0).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(_) ->
  {ok,void}.

handle_event(Event,State) ->
  case Event of
    {f_button,_} -> ok;
    {e_button,_,_} -> ok;
    _ -> probe:add_event(Event)
  end,
  {ok,State}.


  
