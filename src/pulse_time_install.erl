%% Copyright (c) 2014, Lars-Ake Fredlund
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

%% @author Lars-Ake Fredlund (lfredlund@fi.upm.es)
%% @copyright 2011 Lars-Ake Fredlund
%%
%% Install pulse_time in the Erlang lib directory.  This program
%% should be run in the root directory of a pulse_time distribution,
%% which ought to contain a pulse_time-xxx directory.
%% Inspired by eqc_install for the QuickCheck tool
%% (thanks to John Hughes for his kind assistance).

-module(pulse_time_install).
-export([install/0, install/1]).

install() ->
  Erlang = code:where_is_file("erlang.beam"),
  Ebin = filename:dirname(Erlang),
  Erts = filename:dirname(Ebin),
  Lib = filename:dirname(Erts),
  install(Lib).

install(Lib) ->
  io:format("Installation program for pulse_time.~n~n",[]),
  {ok,Dir} = find_pulse_time_distribution(),
  ToDelete = conflicts(Lib,filename:basename(Dir)),
  Version = version(Dir),
  io:format("This will install ~s~nin the directory ~s~n",[Version,Lib]),
  if
    ToDelete=/=[] ->
      io:format
	("This will delete conflicting versions of pulse_time, namely\n"++
	 "    ~p\n",
	 [ToDelete]);
    true ->
      ok
  end,
  case io:get_line("Proceed? ") of
    "y\n" ->
      delete_conflicts(ToDelete),
      install(Lib,Dir);
    _ ->
      io:format("Cancelling install--answer \"y\" at this point to proceed.\n"),
      throw(installation_cancelled)
  end.

conflicts(Lib,Dir) ->
  FullDir = Lib++"/"++Dir,
  case file:read_file_info(FullDir) of
    {ok,_} ->
      [FullDir];
    _ ->
      []
  end.

find_pulse_time_distribution() ->
  OwnLocation = filename:dirname(code:which(?MODULE)),
  {ok,Files} = file:list_dir(OwnLocation),
  MatchingFiles =
    lists:foldl
      (fun (FileName,AccFound) ->
	   case {string:str(FileName,"pulse_time-"),filelib:is_dir(FileName)} of
	     {N,true} when N=/=0 -> [FileName|AccFound];
	     _ -> AccFound
	   end
       end, [], Files),
  case MatchingFiles of
    [Dir] ->
      {ok,OwnLocation++"/"++Dir};
    [] -> 
      io:format
	("*** Error: cannot find pulse_time to install.~n"++
	 "There should be a directory named ``pulse_time-...'' in ~s.~n",
	 [OwnLocation]),
      throw(pulse_time_not_found);
    [_|_] ->
      io:format
	("*** Error: multiple pulse_time versions available to install in ~s.~n"++
	 [OwnLocation]),
      throw(pulse_time_not_found)
  end.

version(Dir) ->
  case code:is_loaded(pulse_time) of
    {file,_} ->
      pulse_time_scheduler:version();
    false ->
      case code:load_abs(Dir++"/ebin/pulse_time_scheduler") of
	{module,_} ->
	  pulse_time_scheduler:version();
	{error,_} ->
	  throw(unknown_version)
      end
  end.

install(Lib,Dir) ->
  copy_pulse_time(Lib,Dir),
  io:format("pulse_time is installed successfully.\n",[]),
  code:add_paths([Lib++"/"++Dir++"/ebin"]).

copy_pulse_time(Lib,Dir) ->
  AppDir = filename:basename(Dir),
  case copy(Dir,Lib++"/"++AppDir) of
    ok ->
      ok;
    eaccess ->
      io:format
	("*** Error: failed to copy pulse_time -- "++
	 "rerun as Administrator or superuser?\n",
	 []),
      exit(eaccess);
    {error,eaccess} ->
      io:format
	("*** Error: failed to copy pulse_time -- "++
	 "rerun as Administrator or superuser?\n",
	 []),
      exit(eaccess);
    Error ->
      io:format
	("*** Error: failed to copy pulse_time -- "++
	 "copy returned~n~p??~n",
	 [Error]),
      exit(Error)
  end.

copy(From,To) ->
  case file:list_dir(From) of
    {ok,Files} ->
      case file:make_dir(To) of
	ok ->
	  lists:foldl
	    (fun (File,ok) ->
		 FromFile = From++"/"++File,
		 ToFile = To++"/"++File,
		 copy(FromFile,ToFile);
		 (_,Status) ->
		 Status
	     end, ok, Files);
	OtherMkDir -> 
	  io:format
	    ("*** Error: failed to create directory ~s due to ~p~n",
	     [To,OtherMkDir]),
	  OtherMkDir
      end;
    _ -> 
      case file:copy(From,To) of
	{ok,_} -> ok;
	OtherCopy -> 
	  io:format
	    ("*** Error: failed to copy ~s to ~s due to ~p~n",
	     [From,To,OtherCopy]),
	  OtherCopy
      end
  end.

delete_conflicts(ToDelete) ->
  lists:foreach
    (fun (Version) ->
	 delete_recursive(Version)
     end, ToDelete).

delete_recursive(F) ->
  case file:list_dir(F) of
    {ok,Files} ->
      lists:foreach
	(fun (File) -> delete_recursive(F++"/"++File) end,
	 Files),
      case file:del_dir(F) of
	ok ->
	  ok;
	Err ->
	  io:format
	    ("*** Error: could not delete directory ~s: ~p\n",
	     [F,Err]),
	  Err
      end;
    _ ->
      case file:delete(F) of
	ok ->
	  ok;
	Err ->
	  io:format
	    ("*** Error: could not delete file ~s: ~p\n",
	     [F,Err]),
	  Err
      end
  end.

