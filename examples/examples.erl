%% Small examples to test the handling of time.

-module(examples).
-compile(export_all).

t0() ->
  Parent = self(),
  PidA = spawn(fun () ->
		   receive 
		      X -> Parent!X
                   after 10 -> Parent!a
                   end
	       end),
  PidB = spawn(fun () ->
		   PidA!b
	       end),
  receive Y -> Y end.

t1() ->
  Parent = self(),
  PidA = spawn(fun () ->
		   pulse_time_scheduler:max_wait_time(infinity),
		   receive 
		      X -> Parent!X
                   after 10 -> Parent!a
                   end
	       end),
  PidB = spawn(fun () ->
		   receive
		     X -> X
		   after 20 -> ok
                   end,
		   PidA!b
	       end),
  receive Y -> Y end.

t2() ->
  Parent = self(),
  PidA = spawn(fun () ->
		   pulse_time_scheduler:max_wait_time(5),
		   receive 
		      X -> Parent!X
                   after 10 -> Parent!a
                   end
	       end),
  PidB = spawn(fun () ->
		   receive
		     X -> X
		   after 20 -> ok
                   end,
		   PidA!b
	       end),
  receive Y -> Y end.








