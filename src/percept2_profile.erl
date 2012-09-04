%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2010. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%  
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%% 

%% 
%% @doc Percept Collector 
%%
%%	This module provides the user interface for the percept data
%	collection (profiling).
%% 

-module(percept2_profile).

-export([start/2, 
         start/3,
         stop/0
      	]).

-include("../include/percept2.hrl").

%%==========================================================================
%%
%% 		Type definitions 
%%
%%==========================================================================
-type port_number() :: integer().

%%==========================================================================
%%
%% 		Interface functions
%%
%%==========================================================================
-spec start(Type :: {file, file:filename()}|{ip, node(),port_number()}, 
            Options::[percept_option()]) ->
                   {'ok', port()} | {'already_started', port()}.
start(Type, Options) ->
    start_profile(Type,Options). 

%%@spec start(string(), MFA::mfa(), [percept_option()]) -> 
%%            ok | {already_started, Port} | {error, not_started}
%%	Port = port()
%%@doc Starts profiling at the entrypoint specified by the MFA. All events are collected, 
%%	this means that processes outside the scope of the entry-point are also profiled. 
%%	No explicit call to stop/0 is needed, the profiling stops when
%%	the entry function returns.
-spec start(Type :: {file, file:filename()}|{ip, port_number()},
	    Entry :: {atom(), atom(), list()},
            Options :: [percept_option()]) ->
	'ok' | {'already_started', port()} |
                   {'error', 'not_started'}.

start(Type, _Entry={Mod, Fun, Args},Options) ->
    case whereis(percept_port) of
	undefined ->
	    start_profile(Type,Options),
            _Res=erlang:apply(Mod, Fun, Args),
            stop();  
	Port ->
	    {already_started, Port}
    end.

deliver_all_trace() -> 
    Tracee = self(),
    Tracer = spawn(fun() -> 
                           receive {Tracee, start} -> ok end,
                           Ref = erlang:trace_delivered(Tracee),
                           receive {trace_delivered, Tracee, Ref} -> Tracee ! {self(), ok} end
                   end),
    erlang:trace(Tracee, true, [procs, {tracer, Tracer}]),
    Tracer ! {Tracee, start},
    receive {Tracer, ok} -> ok end,
    erlang:trace(Tracee, false, [procs]),
    ok.

%% @spec stop() -> ok | {'error', 'not_started'}
%% @doc Stops profiling.
-spec stop() -> 'ok' | {'error', 'not_started'}.
stop() ->
    erlang:system_profile(undefined, [runnable_ports, runnable_procs, 
                                      scheduler, exclusive]),
    erlang:trace(all, false, [all]),
    erlang:trace_pattern({'_', '_', '_'}, false, [local]),
    deliver_all_trace(), 
    case whereis(percept_port) of
    	undefined -> 
	    {error, not_started};
	Port ->
	    erlang:port_command(Port, 
                                erlang:term_to_binary({profile_stop, erlang:now()})),
            erlang:port_close(Port),
       	    ok
    end. 

%%==========================================================================
%%
%% 		Auxiliary functions 
%%
%%==========================================================================
start_profile(Type,Opts) ->
    case whereis(percept_port) of 
	undefined ->
	    io:format("Starting profiling.~n", []),
	    erlang:system_flag(multi_scheduling, block),
            Port = case Type of 
                       {file, FileName} -> 
                         %%  P=(dbg:trace_port(file,{FileName,wrap,".dat",10000000,20}))(),
                           P=(dbg:trace_port(file, FileName))(),
                           P;
                       {ip, Node, Number}->
                           P=(dbg:trace_port(ip, {Number, 50000}))(),
                           {trace_client, Node} ! {self(), {start_profile, Number}},
                           receive 
                               {trace_client, started} -> 
                                   ok
                           end,
                           P
                   end,
            % Send start time
	    erlang:port_command(Port, erlang:term_to_binary({profile_start, erlang:now()})),
	    erlang:system_flag(multi_scheduling, unblock),
            
	    %% Register Port
    	    erlang:register(percept_port, Port),
	    set_tracer(Port, Opts), 
	    {ok, Port};
	Port ->
	    io:format("Profiling already started at port ~p.~n", [Port]),
	    {already_started, Port}
    end.


set_tracer(Port, Opts) ->
    {TraceOpts, ProfileOpts, MatchSpecMFAs} = parse_profile_options(Opts),
    MatchSpec = [{'_', [], [{message, {{cp, {caller}}}}]}],
    [erlang:trace_pattern(MFA, MatchSpec, [local])||MFA<-MatchSpecMFAs],
    erlang:trace(all, true, [{tracer, Port}, timestamp, call, return_to, 
                             set_on_spawn, procs| TraceOpts]),
    erlang:system_profile(Port, ProfileOpts).
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse_profile_options(Opts) ->
    parse_profile_options(Opts, {[],[],[]}).

parse_profile_options([], Out) ->
    Out;
parse_profile_options([Head|Tail],{TraceOpts, ProfileOpts, FuncOpts}) ->
    [Opt|Others] = get_flags(Head),
    NewOpts = Others ++ Tail,
    case Opt of
	procs ->
	    parse_profile_options(
              NewOpts, 
              {[procs|TraceOpts],
               [runnable_procs|ProfileOpts], FuncOpts});
	ports ->
	    parse_profile_options(
              NewOpts,
              {[ports|TraceOpts],
               [runnable_ports|ProfileOpts], FuncOpts});
        scheduler ->
	    parse_profile_options(
              NewOpts, 
              {TraceOpts,
               [scheduler|ProfileOpts], FuncOpts});
        exclusive ->
	    parse_profile_options(
              NewOpts, 
              {TraceOpts,
               [exclusive| ProfileOpts], FuncOpts});
        {function, MFAs} ->
            parse_profile_options(
              NewOpts, 
              {[call, return_to, arity|TraceOpts],
               ProfileOpts, MFAs ++ FuncOpts});
	_ -> 
            case lists:member(Opt, trace_flags()) orelse
                lists:member(Opt, profile_flags()) of
                true ->
                    parse_profile_options(
                      NewOpts, {[Opt|TraceOpts], ProfileOpts, FuncOpts});
                false ->
                    parse_profile_options(
                      NewOpts, {TraceOpts, ProfileOpts, FuncOpts})
            end
    end.

get_flags(concurrency) ->
    [procs, ports, scheduler];
get_flags(process_scheduling)->
    [running, exiting, scheduler_id];
get_flags(message) ->
    [send, 'receive'];
get_flags(gc) ->
    [garbage_collection];
get_flags(Flag={'function', _MFAs}) ->
    [Flag];
get_flags(Flag) ->
    [Flag].

trace_flags()->
    ['all','send','receive','procs','call','silent',
     'return_to','running','exiting','garbage_collection',
     'timestamp','cpu_timestamp','arity','set_on_spawn',
     'set_on_first_spawn','set_on_link','set_on_first_link'].
               
profile_flags()->        
    ['runnable_procs','runnable_ports','scheduler','exclusive'].
