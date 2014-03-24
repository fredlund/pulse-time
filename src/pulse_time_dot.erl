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

-module(pulse_time_dot).
-compile(export_all).

%% State kept during graph drawing
-record(state,
	{processes,         % list of process names, with node index, colour,
			    % and []
	 side_effect=none,  % last node following a side-effect
	 nodes_after=[]     % list of nodes which can be seen to follow last
	                    % side-effect because of message passing.
	}).

dot(FileName,Events) ->
  file:write_file(FileName,unlines(graph(Events))).

unlines([])     -> "";
unlines([X|Xs]) -> X ++ "\n" ++ unlines(Xs).

graph(Events) ->
     [ "digraph {"
     , cluster(root,"red")
     , node(start("root")++",rank=source",root,0,"red")
     ]
  ++ events(#state{processes=[{root,{0,"red",[]}}]},Events)
  ++ [ "}" ].

events(_State,[]) ->
  [];

events(State,[Event|Events]) ->
  case Event of
    {fork, Name1, Name2} ->
      {Name1,{N1,Color,_}} = state(State,Name1),
      NewColor = newColor(State,Color),
      [ cluster(Name2,NewColor)
      , node(start(atom_to_list(Name2)),Name2,0,NewColor)
      , step(Name1,N1,Name2,0,NewColor,"")
      ] ++ events(State#state{
		    processes=[{Name2,{0,NewColor,[]}}|State#state.processes]},
		  Events);
    
    {link, Name1, Name2} ->
      {Name1,{N1,_,_}} = state(State,Name1),
      {Name2,{N2,_,_}} = state(State,Name2),
      [ link(Name1,N1,Name2,N2)
      ] ++ events(State,Events);

    {after0, Name} ->
      {Name,{N,_,_}} = state(State,Name),
      [ msg(Name,N,Name,N,"after0",arrow())
      ] ++ events(State,Events);

%    {yield, Name} ->
%      {Name,{N,_,_}} = state(State,Name),
%      [ msg(Name,N,Name,N,"yield")
%      ] ++ events(State,Events);

    {send, Name1, Msg, Name2} ->
      {Name1,{N1,Color,Q}} = state(State,Name1),
      events(newState(State,Name1,{N1,Color,Q++[{Name2,N1,Msg}]}),Events);

    {exit, Name, Reason} ->
      {Name,{N,Color,Q}} = state(State,Name),
      [ node(stop(""),Name,N+1,Color)
      , step(Name,N,Name,N+1,Color,case Reason of
                                     normal -> "";
                                     _      -> struct_to_list(Reason)
                                   end)
      ] ++
      [ msg(Name1,N1,Name2,N+1,struct_to_list(Msg),discarded())
     || {Name1,{_,_,Q1}} <- State#state.processes
      , {Name2,N1,Msg} <- Q1
      , Name == Name2
      ] ++ events(newState(State,Name,{N+1,Color,Q}),Events);
    
    {deliver, Name1, Msg, Name2} ->
      {Name1,{N1,Color1,Q1}} = state(State,Name1),
      {Name2,{N2,Color2,Q2}} = state(State,Name2),
      {Consumed,Events2} = case Events of
                             [{consumed, Name1, Msg}|OtherEvents] -> {true,OtherEvents};
                             _                                    -> {false,Events}
                           end,
      [ node(small(),Name1,N1+1,Color1)
      , step(Name1,N1,Name1,N1+1,Color1,"")
      ] ++
      case [ Entrya || Entrya = {Name1a,_,Msga} <- Q2, Name1a == Name1, Msga == Msg ] of
        [ Entry = {_,N2a,_} | _ ] ->
          [ msg(Name2,N2a,Name1,N1+1,struct_to_list(Msg),case Consumed of
                                                           true  -> arrow();
                                                           false -> pending() end)
          ] ++ events( newState(newState(
			  State#state{nodes_after=
				      [{Name1,N1+1}
				       || lists:any(
					    fun({AfterName,AfterN}) ->
						    AfterName==Name2 andalso
							AfterN =< N2a
					    end,
					    State#state.nodes_after)]
				      ++State#state.nodes_after}
                     , Name2, {N2,Color2,Q2 -- [Entry]})
                     , Name1, {N1+1,Color1,
			       if Name1==Name2 -> 
				       (Q1 -- [Entry]) ++ [{mymailbox,N1+1,Msg}];
				  Name1/=Name2 -> 
				       Q1 ++ [{mymailbox,N1+1,Msg}]
			       end}
                     ),Events2);
          
        _ ->
          io:format("WARNING: no message '~p' for <~p> in queue ~p from <~p>.~n", [Msg,Name1,Q2,Name2]),
          events(newState(State,Name1,{N1+1,Color1,Q1}),Events2)
      end;

    {consumed, Name1, Msg} ->
      {Name1,{N1,Color1,Q1}} = state(State,Name1),
      Entry = {_,N,_} = case [ Entrya || Entrya = {mymailbox,_,Msga} <- Q1, Msg == Msga ] of
                          [Entryb | _] -> Entryb;
                          _            -> io:format("WARNING: no message '~p' in mailbox ~p of <~p>.~n", [Msg,Q1,Name1]),
                                          {mymailbox,N1,Msg}
                        end,
      [ node(small(),Name1,N1+1,Color1)
      , step(Name1,N1,Name1,N1+1,Color1,"")
      , msg(Name1,N,Name1,N1+1,"",delayed())
      ] ++ events(newState(State,Name1,{N1+1,Color1,Q1 -- [Entry]}),Events);

%    {continue, Name} ->
%      {Name,{N,Color,Q}} = state(State,Name),
%      [ node(Name,N+1,Color)
%      , step(Name,N,Name,N+1,Color,"cont")
%      ] ++ events(newState(State,Name,{N+1,Color,Q}),Events);

    {side_effect, Name, M, F, As, Res} ->
      {Name,{N,Colour,Q}} = state(State,Name),
      [ node(small(),Name,N+1,Colour)
      , step(Name,N,Name,N+1,Colour,io_lib:format("~p:~p~s\\n= ~s",
						  [M,F,argument_list(As), struct_to_list(Res)]))
      ] ++
	      % include arc from last side-effect if there was one,
	      % not evidently preceding this node.
	      [step(LastName,LastN,Name,N,"black","","dashed")
	       || {LastName,LastN} <- [State#state.side_effect],
		  not lists:any(fun({AfterName,_AfterN}) ->
				       AfterName==Name
				end,
				State#state.nodes_after)] ++
	      events(newState(State#state{side_effect={Name,N+1},
					  nodes_after=[{Name,N+1}]},
			      Name,{N+1,Colour,Q}),Events);

    _ ->
      events(State,Events)
  end.

state(State,Name) ->
  case lists:keysearch(Name,1,State#state.processes) of
    {value, T} -> T;
    _          -> exit("name not present")
  end.

newState(State,Name,S) ->
    State#state{processes=
		[ {Name0, case Name == Name0 of
			      true  -> S;
			      false -> S0
			  end}
		  || {Name0, S0} <- State#state.processes]}.

newColor(State,Color0) ->
    {_,Color} = hd (lists:sort( [ { length([ Color1 || {_,{_,Color1,_}} <- State#state.processes, Color == Color1 ])
				    , Color
				   }
				  || Color <- colors(), Color /= Color0
					] )),
    Color.

in_cluster(Name,_Color,S) ->
     "subgraph \"cluster_"
  ++ atom_to_list(Name)
  ++ "\" {"
  ++ S
  ++ " }".

cluster(Name,Color) ->
  in_cluster(Name,Color,
     "label=\""
  ++ atom_to_list(Name)
  ++ "\";"
  ++ "color=" ++ Color ++ ";"
  ).

start(S) -> "shape=triangle,label=\"\"". % " ++ S ++ "\"".
small()  -> "width=0.2,height=0.2,style=filled,label=\"\"".
stop(S)  -> "shape=invtriangle,label=\"" ++ S ++ "\"".

node(Attr,Name,N,Color) ->
  in_cluster(Name,Color,
     "\""
  ++ atom_to_list(Name)
  ++ "_"
  ++ integer_to_list(N)
  ++ "\" ["
  ++ Attr
  ++ ",color="
  ++ Color
  ++ ",group=\""
  ++ atom_to_list(Name)
  ++ "\"]"
  ).

%% node(Name,N,Color) ->
%%   in_cluster(Name,Color,  
%%      "\""
%%   ++ atom_to_list(Name)
%%   ++ "_"
%%   ++ integer_to_list(N)
%%   ++ "\" [color="
%%   ++ Color
%%   ++ ",label=\""
%% %  ++ atom_to_list(Name)
%%   ++ "\"]"
%%   ).

step(Name,N,Name2,N2,Color,S) ->
    step(Name,N,Name2,N2,Color,S,"bold").

step(Name,N,Name2,N2,Color,S,Style) ->
     "\""
  ++ atom_to_list(Name)
  ++ "_"
  ++ integer_to_list(N)
  ++ "\" -> \""
  ++ atom_to_list(Name2)
  ++ "_"
  ++ integer_to_list(N2)
  ++ "\" [style=\"" 
  ++ Style
  ++ "\",color="
  ++ Color
  ++ ",label=\""
  ++ S
  ++ "\""
  ++ case Name == Name2 of
       true  -> ",group=\"" ++ atom_to_list(Name) ++ "\"";
       false -> ""
     end
  ++ "];".

arrow()     -> "arrowhead=normal".
pending()   -> "arrowhead=dot".
delayed()   -> "style=dashed".
discarded() -> "style=dashed,arrowhead=dot".

msg(Name,N,Name2,N2,S,Head) ->
     "\""
  ++ atom_to_list(Name)
  ++ "_"
  ++ integer_to_list(N)
  ++ "\" -> \""
  ++ atom_to_list(Name2)
  ++ "_"
  ++ integer_to_list(N2)
  ++ "\" ["
  ++ Head
  ++ ",color=grey"
  ++ ",label=\""
  ++ S
  ++ "\"];".

link(Name,N,Name2,N2) ->
     "\""
  ++ atom_to_list(Name)
  ++ "_"
  ++ integer_to_list(N)
  ++ "\" -> \""
  ++ atom_to_list(Name2)
  ++ "_"
  ++ integer_to_list(N2)
  ++ "\" [color=grey,style=bold,label=link];".

argument_list(X) ->
  "(" ++ intersperse(",",lists:map(fun struct_to_list/1,X)) ++ ")".

struct_to_list(X) when is_tuple(X) ->
  "{" ++ intersperse(",",lists:map(fun short/1,tuple_to_list(X))) ++ "}";

struct_to_list(X) when is_list(X) ->
  case lists:all(fun(Char) -> Char>=33 andalso Char=<126 end, X) of
      true ->
	  "\\\""++X++"\\\"";
      false ->
	  "[" ++ intersperse(",",lists:map(fun short/1,X)) ++ "]"
  end;

struct_to_list(X) when is_integer(X) -> integer_to_list(X);
struct_to_list(X) when is_atom(X)    -> atom_to_list(X);
struct_to_list(X) when is_pid(X)     -> "<>";
struct_to_list(_X)                   -> "_".

intersperse(_Sep,[])    -> "";
intersperse(_Sep,[X])   -> X;
intersperse(Sep,[X|Xs]) -> X ++ Sep ++ intersperse(Sep,Xs).

short({X})                -> "{" ++ short(X) ++ "}";
short(X) when is_tuple(X) -> "{..}";
short([])                 -> "[]";
short([X])                -> "[" ++ short(X) ++ "]";
short(X) when is_list(X)  -> "[..]";
short(X)                  -> struct_to_list(X).

colors() ->
  ["blue","green","purple","orange","cyan","red","magenta","olivedrab","navy","turqoise"].
