-module(start).

-compile(export_all).

start(InitFloor,NumFloors,NumElevators) ->
  spawn_link
    (fun () ->
	 {ok,Server} = sim_sup:start_link(InitFloor,NumFloors,NumElevators)
     end).

