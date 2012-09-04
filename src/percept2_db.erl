%% 
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2007-2011. All Rights Reserved.
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
%% @doc Percept database.
%%	
%% 
-module(percept2_db).

-export([start/1,
         stop/1,
         insert/2,
         select/1,
         consolidate_db/0,
         gen_compressed_process_tree/0
	]).
 
%% internal export
-export([trace_spawn/2, trace_exit/2, trace_register/2,
         trace_unregister/2, trace_getting_unlinked/2,
         trace_getting_linked/2, trace_link/2,
         trace_unlink/2, trace_in/2, trace_out/2,
         trace_out_exited/2, trace_out_exiting/2,
         trace_in_exiting/2, trace_receive/2, trace_send/2,
         trace_send_to_non_existing_process/2, 
         trace_open/2, trace_closed/2, trace_call/2,
         trace_return_to/2, trace_end_of_trace/2]).

-include("../include/percept2.hrl").

-define(STOP_TIMEOUT, 1000).

-compile(export_all).

%%% ------------------------%%%
%%% 	Type definitions    %%%
%%% ------------------------%%%

-type activity_option() ::
	{ts_min, timestamp()} | 
	{ts_max, timestamp()} | 
	{ts_exact, boolean()} |  
	{mfa, {atom(), atom(), byte()}} | 
	{state, active | inactive} | 
	{id, all | procs | ports | pid() | port()}.

-type scheduler_option() ::
	{ts_min, timestamp()} | 
	{ts_max, timestamp()} |
	{ts_exact, boolean()} |
	{id, scheduler_id()}.

-type system_option() :: start_ts | stop_ts.

-type information_option() ::
	all | procs | ports | pid() | port().

-type filename() :: string()|binary().


%%% ------------------------%%%
%%% 	Interface functions %%%
%%% ------------------------%%%

%% @doc starts the percept database
-spec start([filename()]) ->{started, [{filename(), pid()}]} | 
                            {restarted, [{filename(), pid()}]}.
start(TraceFileNames) ->
    case erlang:whereis(percept_db) of
    	undefined ->
	    {started, do_start(TraceFileNames)};
	PerceptDB ->
	    {restarted, restart(TraceFileNames,PerceptDB)}
    end.

%% @private
%% @doc restarts the percept database.
-spec restart([filename()],pid())-> [{filename(), pid()}].
restart(TraceFileNames, PerceptDB)->
    true=stop_sync(PerceptDB),
    do_start(TraceFileNames).

%% @private
%% @doc starts the percept database.
-spec do_start([filename()])->{pid(), [{filename(), pid()}]}.
do_start(TraceFileNames)->
    Parent = self(),
    _Pid =spawn_link(fun() -> 
                             init_percept_db(Parent, TraceFileNames)
                     end),
    receive
        {percept_db, started, FileNameSubDBPairs} ->
            FileNameSubDBPairs
    end.
    
%% @doc Stops the percept database.
-spec stop(pid()|atom()) -> 'not_started' | {'stopped', pid()}.
stop(Pid) when is_pid(Pid) ->
    Pid! {action, stop},
    {stopped, Pid};

stop(ProcRegName) ->
    case erlang:whereis(ProcRegName) of
        undefined -> 
            not_started;
        Pid -> 
            Pid ! {action, stop},
            {stopped, Pid}
    end.

-spec stop_sync(pid())-> true.
stop_sync(Pid)->
    MonitorRef = erlang:monitor(process, Pid),
    case stop(Pid) of 
        not_started -> true;
        {stopped, Pid1} ->
            receive
                {'DOWN', MonitorRef, _Type, Pid1, _Info}->
                    true;
                {'EXIT', Pid1, _Info} ->
                    true
            after ?STOP_TIMEOUT->
                    erlang:demonitor(MonitorRef, [flush]),
                    exit(Pid1, kill)
            end
    end.

stop_percept_db(FileNameSubDBPairs) ->
    ok = stop_percept_sub_dbs(FileNameSubDBPairs),
    ets:delete(pdb_warnings),
    ets:delete(pdb_info),
    ets:delete(pdb_system),
    ets:delete(funcall_info),
    ets:delete(fun_calltree),
    ets:delete(fun_info),
    ets:delete(inter_node),
    case ets:info(history_html) of
        undefined -> 
            stopped;
        _ ->
            ets:delete_all_objects(history_html),
            stopped
    end.

stop_percept_sub_dbs(FileNameSubDBPairs) ->
    percept2_utils:pforeach(
      fun({_FileName, SubDB}) ->
              true=stop_sync(SubDB)
      end, FileNameSubDBPairs).
    
%% @doc Inserts a trace or profile message to the database.  
-spec insert(pid()|atom(), tuple()) -> ok.
insert(SubDB, Trace) -> 
    SubDB ! {insert, Trace},
    ok.

%% @spec select({atom(), Options}) -> Result
%% @doc Synchronous call. Selects information based on a query.
%% 
%% <p>Queries:</p>
%% <pre>
%% {system, Option}
%%	Option = system_option()
%%	Result = timestamp() 
%% {information, Options}
%%	Options = [information_option()]
%%	Result = [#information{}] 
%% {scheduler, Options}
%%	Options = [sceduler_option()]
%%	Result = [#activity{}]
%% {activity, Options}
%%	Options = [activity_option()]
%%	Result = [#activity{}]
%% </pre>
%% <p>
%% Note: selection of Id's are always OR all other options are considered AND.
%% </p>
-spec select({system, system_option()} | 
             {information, information_option()}| 
             {scheduler, scheduler_option()}|
             {activity, activity_option()}) ->
                    timestamp()|list().
                  
select(Query) ->
    percept_db ! {select, self(), Query},
    receive {result, Match} ->
            Match 
    end.

consolidate_db() ->
    percept_db ! {action, self(), consolidate_db},
    receive
        {percept_db, consolidate_done} ->
            ok
    end.

%%% ------------------------%%%
%%% 	Database loop       %%%
%%% ------------------------%%%

-spec init_percept_db(pid(), [filename()]) -> any().
init_percept_db(Parent, TraceFileNames) ->
    process_flag(trap_exit, true),
    register(percept_db, self()),
    ets:new(pdb_warnings, [named_table, public, {keypos, 1}, ordered_set]),
    ets:new(pdb_info, [named_table, public, {keypos, #information.id}, set]),
    ets:new(pdb_system, [named_table, public, {keypos, 1}, set]),
    ets:new(funcall_info, [named_table, public, {keypos, #funcall_info.id}, ordered_set,
                           {read_concurrency,true}]),
    ets:new(fun_calltree, [named_table, public, {keypos, #fun_calltree.id}, ordered_set,
                           {read_concurrency,true}]),
    ets:new(fun_info, [named_table, public, {keypos, #fun_info.id}, 
                       ordered_set,{read_concurrency, true}]),
    ets:new(inter_node, [named_table, public, 
                                 {keypos,#inter_node.timed_from_node}, ordered_set]), 
    FileNameSubDBPairs=start_percept_sub_dbs(TraceFileNames),
    Parent!{percept_db, started, FileNameSubDBPairs},
    loop_percept_db(FileNameSubDBPairs).

loop_percept_db(FileNameSubDBPairs) ->
    receive
     	{select, Pid, Query} ->
            Res = percept_db_select_query(FileNameSubDBPairs, Query),
            Pid ! {result, Res},
	    loop_percept_db(FileNameSubDBPairs);
	{action, stop} ->
            stop_percept_db(FileNameSubDBPairs);
	{action, From, consolidate_db} ->
            consolidate_db(FileNameSubDBPairs),
            From ! {percept_db, consolidate_done},
	    loop_percept_db(FileNameSubDBPairs);
        {operate, Pid, {Table, {Fun, Start}}} ->
	    Result = ets:foldl(Fun, Start, Table),
	    Pid ! {result, Result},
	    loop_percept_db(FileNameSubDBPairs);
        {'EXIT', _, normal} ->
            loop_percept_db(FileNameSubDBPairs);
	Unhandled -> 
	    io:format("loop_percept_db, unhandled query: ~p~n", [Unhandled]),
	    loop_percept_db(FileNameSubDBPairs)
    end.

loop_percept_sub_db(SubDBIndex) ->
    receive
        {insert, Trace} ->
            insert_trace(SubDBIndex,Trace),
            loop_percept_sub_db(SubDBIndex);
        {select, Pid, Query} ->
            io:format("loop_percept_sub_db query:~p\n", [Query]),
            Pid ! {self(), percept_sub_db_select_query(SubDBIndex, Query)},
            loop_percept_sub_db(SubDBIndex);
        {action, stop} ->
            stop_a_percept_sub_db(SubDBIndex);
        Msg ->
            io:format("loop_percept_sub_db:~p\n", [Msg]),
            loop_percept_sub_db(SubDBIndex)
    end.

start_percept_sub_dbs(TraceFileNames) ->
    Self = self(),
    IndexList = lists:seq(1, length(TraceFileNames)),
    IndexedTraceFileNames = lists:zip(IndexList, TraceFileNames),
    lists:map(fun({Index, FileName})->
                      SubDBPid = spawn_link(fun()->
                                                    start_a_percept_sub_db(Self, {Index, FileName})
                                            end),
                      receive
                          {percept_sub_db_started, {FileName, SubDBPid}} ->
                              {FileName, SubDBPid}
                      end                      
              end, IndexedTraceFileNames).

start_a_percept_sub_db(Parent, {Index, TraceFileName}) ->
    process_flag(trap_exit, true),
    Scheduler = mk_proc_reg_name("pdb_scheduler", Index),
    Activity = mk_proc_reg_name("pdb_activity", Index),
    ProcessInfo = mk_proc_reg_name("pdb_info", Index),
    System = mk_proc_reg_name("pdb_system", Index),
    FuncInfo = mk_proc_reg_name("pdb_func", Index),
    Warnings = mk_proc_reg_name("pdb_warnings", Index),
    io:format("starting a percept_sub_db...\n"),
    start_child_process(Scheduler, fun init_pdb_scheduler/2),
    start_child_process(Activity, fun init_pdb_activity/2),
    start_child_process(ProcessInfo, fun init_pdb_info/2),
    start_child_process(System, fun init_pdb_system/2),
    start_child_process(FuncInfo, fun init_pdb_func/2),
    start_child_process(Warnings, fun init_pdb_warnings/2),
    Parent ! {percept_sub_db_started, {TraceFileName, self()}},
    loop_percept_sub_db(Index).

start_child_process(ProcRegName, Fun) ->
    Parent=self(),
    Pid=spawn_link(fun() -> Fun(ProcRegName, Parent) end),
    receive
        {ProcRegName, started} ->
            io:format("Process ~p started, Pid:~p\n", [ProcRegName, Pid]),
            ok;
        Msg ->
            io:format("Unexpected message:\n~p\n", [Msg])            
    end.

-spec stop_a_percept_sub_db(integer()) -> true.
stop_a_percept_sub_db(SubDBIndex) ->
    Scheduler = mk_proc_reg_name("pdb_scheduler", SubDBIndex),
    Activity = mk_proc_reg_name("pdb_activity", SubDBIndex),
    ProcessInfo = mk_proc_reg_name("pdb_info", SubDBIndex),
    System = mk_proc_reg_name("pdb_system", SubDBIndex),
    FuncInfo = mk_proc_reg_name("pdb_func", SubDBIndex),
    Warnings = mk_proc_reg_name("pdb_warnings", SubDBIndex),
    case ets:info(Scheduler) of 
        undefined -> 
            io:format("Table does not exist\n"),
            ok;
        _ ->                     
            ets:delete(Scheduler)
    end,
    case ets:info(Activity) of 
        undefined -> ok;
        _ -> ets:delete(Activity)
    end,
    true = stop_sync(Scheduler),
    true = stop_sync(Activity),
    true = stop_sync(ProcessInfo),
    true = stop_sync(System),
    true = stop_sync(FuncInfo),
    true = stop_sync(Warnings).      


%%% -----------------------------%%%
%%%        query database        %%%
%%% -----------------------------%%%
%%% select_query
%%% In:
%%%	Query = {InfoType, Option}
%%%	InfoType = system | activity | scheduler |
%%                 information |code | funs      |
%%                 calltime
percept_db_select_query(FileNameSubDBPairs, Query) ->
    case Query of
	{system, _ } -> 
	    select_query_system(Query);
	{activity, _ } -> 
	    select_query_activity(FileNameSubDBPairs, Query);
    	{scheduler, _} ->
	    select_query_scheduler(FileNameSubDBPairs, Query);
	{information, _ } -> 
	    select_query_information(Query);
        {code, _} ->
            select_query_func(Query);
        {funs, _} ->
            select_query_func(Query);
        {calltime, _} ->
            select_query_func(Query);
        Unhandled ->
	    io:format("select_query, unhandled: ~p~n", [Unhandled]),
	    []
    end.

percept_sub_db_select_query(SubDBIndex, Query) ->
    io:format("Subdb query:\n~p\n", [{SubDBIndex, Query}]),
    case Query of 
        {activity, _ } -> 
	    select_query_activity_1(SubDBIndex, Query);
        {scheduler, _} ->
            select_query_scheduler_1(SubDBIndex, Query);
        Unhandled ->
	    io:format("percept_sub_db_select_query, unhandled: ~p~n", [Unhandled]),
	    []
    end.

select_query_func(Query) ->
    case Query of 
        {code, Options} when is_list(Options) ->
            Head = #funcall_info{
              id={'$1', '$2'}, 
              end_ts='$3',
              _='_'},
            Body =  ['$_'],
            MinTs = proplists:get_value(ts_min, Options, undefined),
            MaxTs = proplists:get_value(ts_max, Options, undefined),
            Constraints = [{'not', {'orelse', {'>=',{const, MinTs},'$3'},
                                    {'>=', '$2', {const,MaxTs}}}}],
            ets:select(funcall_info, [{Head, Constraints, Body}]);
        {funs, Options} when Options==[] ->
            Head = #fun_info{
              id={'$1', '$2'}, 
              _='_'},
            Body =  ['$_'],
            Constraints = [],
            ets:select(fun_info, [{Head, Constraints, Body}]);
        {funs, Id={_Pid, _MFA}} ->
            Head = #fun_info{
              id=Id, 
              _='_'},
            Body =  ['$_'],
            Constraints = [],
            ets:select(fun_info, [{Head, Constraints, Body}]);
        {calltime, Pid={pid,{P1,P2,P3}}}->
            Head = #fun_info{id={Pid,'$1'} ,
                             _='_', call_count='$2',
                             acc_time='$3'},
            Constraints = [],
            Body =[{{{{{{pid, {{P1,P2, P3}}}},'$3'}}, '$1', '$2'}}],
            ets:select(fun_info, [{Head, Constraints, Body}]);
        Unhandled ->
            io:format("select_query_func, unhandled: ~p~n", [Unhandled]),
	    []
    end.

%%%========================================%%%
%%%                                        %%%
%%% 	process trace events               %%%
%%%                                        %%%
%%%========================================%%%
-type dest()::pid()|port()|atom()|{atom, node()}.
-spec same_node_pids(dest(), dest()) -> boolean().

same_node_pids(Pid1, Pid2) 
  when is_pid(Pid1) andalso is_pid(Pid2)->
    Pid1Str = pid_to_list(Pid1),
    [P1,_,_] = string:tokens(Pid1Str,"."),
    Pid2Str = pid_to_list(Pid2),
    [P2,_,_] = string:tokens(Pid2Str, "."),
    P1 == P2;
same_node_pids(Pid1, Pid2) 
  when is_atom(Pid1);is_atom(Pid2) ->
    true;
same_node_pids({RegName, Node}, Pid2) 
  when is_pid(Pid2) ->
    same_node_pids(Pid2, {RegName, Node});
same_node_pids(Pid1, {_RegName, Node})
  when is_pid(Pid1)->
    case node(Pid1) of 
        nonode@nohost ->
            true;
        Node1 ->
            Node1 ==Node
    end;    
same_node_pids({_, Node1}, {_, Node2})->
    Node1 == Node2;
same_node_pids(_, _) -> true.

-spec get_node_name(port()|pid()|reference()|{atom(),node()})
                   -> node().
get_node_name({_RegName, Node}) ->    
    Node;
get_node_name(Arg) -> 
    node(Arg).

insert_trace(SubDBIndex,Trace) ->
    case element(1, Trace) of
        trace_ts -> 
            Type=element(3, Trace),
            FunName = list_to_atom("trace_"++atom_to_list(Type)),
            ?MODULE:FunName(SubDBIndex, Trace);
        _ ->
            insert_profile_trace(SubDBIndex,Trace)
    end.                  

insert_profile_trace(SubDBIndex,Trace) ->
    case Trace of
        {profile_start, Ts} ->
            SystemProcRegName =mk_proc_reg_name("pdb_system", SubDBIndex),
            update_system_start_ts(SystemProcRegName,Ts);
        {profile_stop, Ts} ->
            SystemProcRegName =mk_proc_reg_name("pdb_system", SubDBIndex),
            update_system_stop_ts(SystemProcRegName,Ts);
        {profile, Id, State, Mfa, TS} when is_pid(Id) ->
            ActivityProcRegName = mk_proc_reg_name("pdb_activity", SubDBIndex),
            insert_profile_trace_1(ActivityProcRegName,Id,State,Mfa,TS,procs);
        {profile, Id, State, Mfa, TS} when is_port(Id) ->
            ActivityProcRegName = mk_proc_reg_name("pdb_activity", SubDBIndex),
            insert_profile_trace_1(ActivityProcRegName, Id, State, Mfa, TS, ports);
        {profile, scheduler, Id, State, NoScheds, Ts} ->
            Act= #scheduler{
              timestamp = Ts,
              id =  Id,
              state = State,
              active_scheds = NoScheds},
              % insert scheduler activity
            SchedulerProcRegName = mk_proc_reg_name("pdb_scheduler",
                                                    SubDBIndex),
            update_scheduler(SchedulerProcRegName, Act);
        _Unhandled ->
            io:format("unhandled trace: ~p~n", [_Unhandled])
    end.
insert_profile_trace_1(ProcRegName,Id,State,Mfa,TS,_Type) ->
    update_activity(ProcRegName,
                    #activity{id = Id,
                              state = State,
                              timestamp = TS,
                              where = Mfa}).

check_activity_consistency(Id, State, RunnableStates) ->
    case lists:keyfind(Id,1,RunnableStates) of 
        {Id, State} ->
            invalid_state;
        false when State == inactive ->
            invalid_state;
        false ->
            [{Id, State}|RunnableStates];
        _ ->
            lists:keyreplace(Id, 1, RunnableStates, {Id, State})
    end.

trace_spawn(SubDBIndex, _Trace={trace_ts, Parent, spawn, Pid, Mfa, TS}) when is_pid(Pid) ->
    ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
    InformativeMfa = mfa2informative(Mfa),
    update_information(ProcRegName,
                       #information{id = percept2_utils:pid2value(Pid), start = TS,
                                    parent = Parent, entry = InformativeMfa}),
    update_information_child(ProcRegName, percept2_utils:pid2value(Parent), Pid).

trace_exit(SubDBIndex,_Trace= {trace_ts, Pid, exit, _Reason, TS}) when is_pid(Pid)->
    ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
    update_information(ProcRegName, #information{id = percept2_utils:pid2value(Pid), stop = TS}).

trace_register(SubDBIndex,_Trace={trace_ts, Pid, register, Name, _Ts}) when is_pid(Pid)->
    ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
    update_information(ProcRegName, #information{id = percept2_utils:pid2value(Pid), name = Name}).
 
trace_unregister(_SubDBIndex, _Trace)->
    ok.  

trace_getting_unlinked(_SubDBIndex, _Trace) ->
    ok.

trace_getting_linked(_SubDBIndex, _Trace) ->
    ok.
trace_link(_SubDBIndex,_Trace) ->
    ok.

trace_unlink(_SubDBIndex, _Trace) ->
    ok.

trace_in(SubDBIndex, _Trace={trace_ts, Pid, in, Rq,  _MFA, Ts})->
    if is_pid(Pid) ->
            ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
            update_information_rq(ProcRegName, percept2_utils:pid2value(Pid), {Ts, Rq});
       true -> ok
    end;
trace_in(_SubDBIndex, _Trace={trace_ts, _Pid, in, _MFA, _Ts}) ->
    ok.
            
trace_out(_SubDBIndex, _Trace={trace_ts, Pid, out, _Rq,  _MFA, TS}) 
  when is_pid(Pid) ->
    %%TODO:  Need to be fixed.
    case erlang:get(Pid) of 
         undefined -> io:format("No In time\n");
        InTime ->
            Elapsed = elapsed(InTime, TS),
             erlang:erase(Pid),
             ets:update_counter(pdb_info, Pid, {13, Elapsed})
    end;
trace_out(_SubDBIndex, _Trace={trace_ts, Pid, out, _MFA, _Ts})
  when is_pid(Pid) ->
    ok;
trace_out(_, _) ->
    ok.

elapsed({Me1, S1, Mi1}, {Me2, S2, Mi2}) ->
    Me = (Me2 - Me1) * 1000000,
    S  = (S2 - S1 + Me) * 1000000,
    Mi2 - Mi1 + S.

trace_out_exited(_SubDBIndex, _Trace={trace_ts, _Pid, out_exited, _, _Ts}) ->
    ok.

trace_out_exiting(_SubDBIndex, _Trace={trace_ts, _Pid, out_exiting, _, _Ts}) ->
    ok.

trace_in_exiting(_SubDBIndex, _Trace={trace_ts, _Pid, in_exiting, _, _Ts}) ->
    ok.

trace_receive(SubDBIndex, _Trace={trace_ts, Pid, 'receive', MsgSize, _Ts}) ->
    if is_pid(Pid) ->
            ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
            update_information_received(ProcRegName, percept2_utils:pid2value(Pid), erlang:external_size(MsgSize));
       true ->
            ok
    end.

trace_send(SubDBIndex,_Trace= {trace_ts, Pid, send, MsgSize, To, Ts}) ->
    if is_pid(Pid) ->
            ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
            update_information_sent(ProcRegName, percept2_utils:pid2value(Pid), erlang:external_size(MsgSize), To, Ts);
       true ->
            ok
    end.

trace_send_to_non_existing_process(SubDBIndex,
  _Trace={trace_ts, Pid, send_to_non_existing_process, Msg, _To, Ts})->
    if is_pid(Pid) ->
            ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
            update_information_sent(ProcRegName, percept2_utils:pid2value(Pid), erlang:external_size(Msg), none, Ts);
       true ->
            ok
    end.

trace_open(SubDBIndex, _Trace={trace_ts, Caller, open, Port, Driver, TS})->
    ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
    update_information(ProcRegName, #information{
                          id = Port, entry = Driver, start = TS, parent = Caller}).

trace_closed(SubDBIndex,_Trace={trace_ts, Port, closed, _Reason, Ts})->
    ProcRegName = mk_proc_reg_name("pdb_info", SubDBIndex),
    update_information(ProcRegName, #information{id = Port, stop = Ts}).

trace_call(SubDBIndex, _Trace={trace_ts, Pid, call, MFA,{cp, CP}, TS}) ->
    trace_call(SubDBIndex, Pid, MFA, TS, CP).

trace_return_to(SubDBIndex,_Trace={trace_ts, Pid, return_to, MFA, TS}) ->
    trace_return_to(SubDBIndex, Pid, MFA, TS).

trace_end_of_trace(SubDBIndex, {trace_ts, Parent, end_of_trace}) ->
    ProcRegName =mk_proc_reg_name("pdb_func", SubDBIndex),
    ProcRegName ! {self(), end_of_trace_file},
    receive 
        {SubDBIndex, done} ->
            Parent ! {self(), done}
    end.
 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             access to pdb_warnings               %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init_pdb_warnings(ProcRegName, Parent) ->
    register(ProcRegName, self()),
    Parent !{ProcRegName, started},
    pdb_warnings_loop().

pdb_warnings_loop()->
    receive
        {action, stop} ->
            ok 
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             access to pdb_activity               %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init_pdb_activity(ProcRegName, Parent) ->
    register(ProcRegName, self()),
    ets:new(ProcRegName, [named_table, protected, 
                          {keypos, #activity.timestamp},
                          ordered_set]),
    Parent !{ProcRegName, started},
    pdb_activity_loop().

update_activity(ProcRegName, Activity) ->
    ProcRegName ! {update_activity, {ProcRegName, Activity}}.
    

select_query_activity(FileNameSubDBPairs, Query) ->
    io:format("select_query_activity:\n~p\n", [Query]),
    Res = percept2_utils:pmap(
            fun({_, SubDB}) ->
                    SubDB ! {select, self(), Query},
                    receive
                        {SubDB, Res} ->
                            Res
                    end
            end, FileNameSubDBPairs),
    case Query of 
        {activity,{min_max_ts, _}} ->
            {Mins,Maxs}=lists:unzip(lists:append(Res)),
            {case Mins of [] -> undefined; _ -> lists:min(Mins) end,
             case Maxs of [] -> undefined; _ -> lists:max(Maxs) end};
        _ ->
            lists:append(Res)
    end.

pdb_activity_loop()->
    receive 
        {update_activity, {SubTab,Activity}} ->
            ets:insert(SubTab, Activity),
            pdb_activity_loop();
        {consolidate_runnability, {From, SubDBIndex, {ActiveProcs, ActivePorts, RunnableStates}}} ->
            {ok, {NewActiveProcs, NewActivePorts, NewRunnableStates}}=
                do_consolidate_runnability(SubDBIndex, {ActiveProcs, ActivePorts}, RunnableStates), 
            From!{self(), done, {NewActiveProcs, NewActivePorts, NewRunnableStates}},
            pdb_activity_loop();
        {action, stop} ->
            ok            
    end.
do_consolidate_runnability(SubDBIndex, {ActiveProcs, ActivePorts},RunnableStates) ->
    Tab=mk_proc_reg_name("pdb_activity", SubDBIndex),
    put({runnable, procs}, ActiveProcs),
    put({runnable, ports}, ActivePorts),
    consolidate_runnability_loop(Tab, ets:first(Tab), RunnableStates).

consolidate_runnability_loop(_Tab, '$end_of_table',RunnableStates) ->
    {ok, {get({runnable, procs}), get({runnable, ports}), RunnableStates}};
consolidate_runnability_loop(Tab, Key, RunnableStates) ->
    case ets:lookup(Tab, Key) of
	[#activity{id = Id, state = State }] ->
            case check_activity_consistency(Id, State,RunnableStates) of 
                invalid_state ->
                    NextKey = ets:next(Tab, Key),
                    ets:delete(Tab, Key),
                    consolidate_runnability_loop(Tab, NextKey, RunnableStates);
                NewRunnableStates when is_pid(Id)->
                    Rc = get_runnable_count(procs, State),
                    ets:update_element(Tab, Key, {#activity.runnable_count, 
                                                  {Rc, get({runnable, ports})}}),
                    consolidate_runnability_loop(Tab, ets:next(Tab, Key), NewRunnableStates);
                NewRunnableStates when is_port(Id)->
                    Rc = get_runnable_count(ports, State),
                    ets:update_element(Tab, Key, {#activity.runnable_count, 
                                                  {get({runnable, ports}), Rc}}),
                    consolidate_runnability_loop(Tab, ets:next(Tab, Key), NewRunnableStates)
            end
    end.
  
%% get_runnable_count(Type, Id, State) -> RunnableCount
%% In: 
%%	Type = procs | ports
%%	State = active | inactive
%% Out:
%%	RunnableCount = integer()
%% Purpose:
%%	Keep track of the number of runnable ports and processes
%%	during the profile duration.
get_runnable_count(Type, State) ->
    case {get({runnable, Type}), State} of 
        {N, active} ->
            put({runnable, Type}, N + 1),
            N + 1;
        {N, inactive} ->
            put({runnable, Type}, N - 1),
            N - 1;
        Unhandled ->
	    io:format("get_runnable_count, unhandled ~p~n", [Unhandled]),
	    Unhandled
    end.

%%% select_query_activity
select_query_activity_1(SubDBIndex, Query) ->
    case Query of
        {activity, {runnable_counts, Options}} ->
            get_runnable_counts(SubDBIndex, Options);
        {activity, {min_max_ts, Pids}} ->
            Head = #activity{timestamp ='$1', id ='$2', _='_'},
            Body = ['$1'],
            MS= [{Head, [{'==', Head#activity.id, Pid}], Body}||Pid<-Pids],
            Tab = mk_proc_reg_name("pdb_activity", SubDBIndex),
            case ets:select(Tab, MS) of 
                [] -> [];
                TSs ->[{hd(TSs), lists:last(TSs)}]
            end;
        {activity, Options} when is_list(Options) ->
            case lists:member({ts_exact, true},Options) of
                true ->
                    case catch select_query_activity_exact_ts(SubDBIndex, Options) of
                    {'EXIT', Reason} ->
                            io:format(" - select_query_activity [ catch! ]: ~p~n", [Reason]),
			    [];
		    	Match ->
			    Match
		    end;		    
		false ->
		    MS = activity_ms(Options),
                    Tab = mk_proc_reg_name("pdb_activity", SubDBIndex),
                    case catch ets:select(Tab, MS) of
		    {'EXIT', Reason} ->
	                    io:format(" - select_query_activity [ catch! ]: ~p~n", [Reason]),
			    [];
		    	Match ->
                            io:format("~p items found in tab ~p\n", [length(Match), Tab]),
                            Match
		    end
	    end;
	Unhandled ->
	    io:format("select_query_activity, unhandled: ~p~n", [Unhandled]),
    	    []
    end.

%% This only works when all the procs/ports are selected.
get_runnable_counts(SubDBIndex, Options) ->
    MS = activity_count_ms(Options),
    Tab = mk_proc_reg_name("pdb_activity", SubDBIndex),
    case catch ets:select(Tab, MS) of
        {'EXIT', Reason} ->
            io:format(" - select_query_activity [ catch! ]: ~p~n", [Reason]),
            [];
        Match ->
            io:format("~p items found in tab ~p\n", [length(Match), Tab]),
            Match
    end.
         

select_query_activity_exact_ts(SubDBIndex, Options) ->
    case { proplists:get_value(ts_min, Options, undefined), 
           proplists:get_value(ts_max, Options, undefined) } of
	{undefined, undefined} -> [];
	{undefined, _        } -> [];
	{_        , undefined} -> [];
	{TsMin    , TsMax    } ->
            Tab = mk_proc_reg_name("pdb_activity", SubDBIndex),
	    % Remove unwanted options
	    Opts = lists_filter([ts_exact], Options),
	    Ms = activity_ms(Opts),
	    case ets:select(Tab, Ms) of
		% no entries within interval
		[] -> 
		    Opts2 = lists_filter([ts_max, ts_min], Opts) ++ [{ts_min, TsMax}],
		    Ms2   = activity_ms(Opts2),
		    case ets:select(Tab, Ms2, 1) of
			'$end_of_table' -> [];
			{[E], _}  -> 
			    [PrevAct] = ets:lookup(Tab, ets:prev(Tab, E#activity.timestamp)),
			    [PrevAct#activity{ timestamp = TsMin} , E] 
		    end;
		Acts=[Head|_] ->
                    if
			Head#activity.timestamp == TsMin -> Acts;
			true ->
			    PrevTs = ets:prev(Tab, Head#activity.timestamp),
			    case ets:lookup(Tab, PrevTs) of
				[] -> Acts;
				[PrevAct] -> [PrevAct#activity{timestamp = TsMin}|Acts]
			    end
		    end
	    end
    end.

lists_filter([], Options) -> Options;
lists_filter([D|Ds], Options) ->
    lists_filter(Ds, lists:filter(
	fun ({Pred, _}) ->
	    if 
		Pred == D -> false;
		true      -> true
	    end
	end, Options)).

% Options:
% {ts_min, timestamp()}
% {ts_max, timestamp()}
% {mfa, mfa()}
% {state, active | inactive}
% {id, all | procs | ports | pid() | port()}
%
% All options are regarded as AND expect id which are regarded as OR
% For example: [{ts_min, TS1}, {ts_max, TS2}, {id, PID1}, {id, PORT1}] would be
% ({ts_min, TS1} and {ts_max, TS2} and {id, PID1}) or
% ({ts_min, TS1} and {ts_max, TS2} and {id, PORT1}).

activity_ms(Opts) ->
    Head = #activity{
    	timestamp = '$1',
	id = '$2',
	state = '$3',
	where = '$4',
	_ = '_'},

    {Conditions, IDs} = activity_ms_and(Head, Opts, [], []),
    Body = ['$_'],
    
    lists:foldl(
    	fun (Option, MS) ->
	    case Option of
		{id, ports} ->
	    	    [{Head, [{is_port, Head#activity.id} | Conditions], Body} | MS];
		{id, procs} ->
	    	    [{Head,[{is_pid, Head#activity.id} | Conditions], Body} | MS];
		{id, ID} when is_pid(ID) ; is_port(ID) ->
	    	    [{Head,[{'==', Head#activity.id, ID} | Conditions], Body} | MS];
		{id, all} ->
	    	    [{Head, Conditions,Body} | MS];
		_ ->
	    	    io:format("activity_ms id dropped ~p~n", [Option]),
	    	    MS
	    end
	end, [], IDs).

activity_count_ms(Opts) ->
    % {activity, Timestamp, State, Mfa}
    Head = #activity{
    	timestamp = '$1',
        id = '$2',
        state = '$3',
        where = '$4',
        runnable_count='$5'
	},

    {Conditions, IDs} = activity_ms_and(Head, Opts, [], []),
    Body = [{{'$1', '$5'}}],
    lists:foldl(
    	fun (Option, MS) ->
	    case Option of
		{id, ports} ->
	    	    [{Head, [{is_port, Head#activity.id} | Conditions], Body} | MS];
		{id, procs} ->
	    	    [{Head,[{is_pid, Head#activity.id} | Conditions], Body} | MS];
                {id, all} ->
	    	    [{Head, Conditions,Body} | MS];
		_ ->
	    	    io:format("activity_ms id dropped ~p~n", [Option]),
	    	    MS
	    end
	end, [], IDs).

activity_ms_and(_, [], Constraints, []) ->
    {Constraints, [{id, all}]};
activity_ms_and(_, [], Constraints, IDs) -> 
    {Constraints, IDs};
activity_ms_and(Head, [Opt|Opts], Constraints, IDs) ->
    case Opt of
	{ts_min, Min} ->
	    activity_ms_and(Head, Opts, 
		[{'>=', Head#activity.timestamp, {Min}} | Constraints], IDs);
	{ts_max, Max} ->
	    activity_ms_and(Head, Opts, 
		[{'=<', Head#activity.timestamp, {Max}} | Constraints], IDs);
	{id, ID} ->
	    activity_ms_and(Head, Opts, 
		Constraints, [{id, ID} | IDs]);
	{state, State} ->
	    activity_ms_and(Head, Opts, 
		[{'==', Head#activity.state, State} | Constraints], IDs);
	{mfa, Mfa} ->
	    activity_ms_and(Head, Opts, 
		[{'==', Head#activity.where, {Mfa}}| Constraints], IDs);
	_ -> 
	    io:format("activity_ms_and option dropped ~p~n", [Opt]),
	    activity_ms_and(Head, Opts, Constraints, IDs)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             access to pdb_scheduler              %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init_pdb_scheduler(ProcRegName, Parent) ->
    register(ProcRegName, self()),
    ets:new(ProcRegName, [named_table, protected, 
                          {keypos, #scheduler.timestamp},
                          ordered_set]),
    Parent ! {ProcRegName, started},    
    pdb_scheduler_loop().
    
update_scheduler(SchedulerProcRegName,Activity) ->
    SchedulerProcRegName ! {update_scheduler, 
                            {SchedulerProcRegName,Activity}}.

select_query_scheduler(FileNameSubDBPairs, Query) ->
    Res = percept2_utils:pmap(
            fun({_, SubDB}) ->
                    SubDB ! {select, self(), Query},
                    receive
                        {SubDB, Res} ->
                            Res
                    end
            end, FileNameSubDBPairs),
    lists:append(Res).

pdb_scheduler_loop()->
    receive
        {update_scheduler, {SchedulerProcRegName,Activity}} ->
            ets:insert(SchedulerProcRegName, Activity),
            pdb_scheduler_loop();
        {action, stop} ->
            ok
    end.

select_query_scheduler_1(SubDBIndex, Query) ->
    case Query of
	{scheduler, Options} when is_list(Options) ->
            Head = #scheduler{
	    	timestamp = '$1',
		id = '$2',
		state = '$3',
		active_scheds = '$4'
             },
	    Body = ['$_'],
	    % We don't need id's
            Constraints = scheduler_ms_and(Head, Options, []),
            Tab = mk_proc_reg_name("pdb_scheduler", SubDBIndex),
            ets:select(Tab, [{Head, Constraints, Body}]);
	Unhandled ->
	    io:format("select_query_scheduler_1, unhandled: ~p~n", [Unhandled]),
	    []
    end.

scheduler_ms_and(_, [], Constraints) -> 
    Constraints;
scheduler_ms_and(Head, [Opt|Opts], Constraints) ->
    case Opt of
	{ts_min, Min} ->
	    scheduler_ms_and(Head, Opts, 
                             [{'>=', Head#scheduler.timestamp, {Min}} | Constraints]);
        {ts_max, Max} ->
	    scheduler_ms_and(Head, Opts, 
                             [{'=<', Head#scheduler.timestamp, {Max}} | Constraints]);
	_ -> 
	    io:format("scheduler_ms_and option dropped ~p~n", [Opt]),
	    scheduler_ms_and(Head, Opts, Constraints)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             access to pdb_info                   %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init_pdb_info(ProcRegName, Parent) ->
    register(ProcRegName, self()),
    Parent ! {ProcRegName, started},
    pdb_info_loop().

update_information(ProcRegName, Info) ->
    ProcRegName!{update_information, Info}.

update_information_child(ProcRegName, Id, Child) ->
    ProcRegName!{update_information_child, {Id, Child}}.

update_information_rq(ProcRegName, Pid, {Ts,Rq}) ->
    ProcRegName!{update_information_rq, {Pid, {Ts, Rq}}}.

update_information_sent(ProcRegName, From, MsgSize, To, Ts) ->
    ProcRegName!{update_information_sent, {From, MsgSize, To, Ts}}.

update_information_received(ProcRegName, Pid, MsgSize)->
    ProcRegName!{update_information_received, {Pid, MsgSize}}.

update_information_element(ProcRegName, Key, {Pos, Value}) ->
    ProcRegName! {update_information_element, {Key, {Pos, Value}}}.


pdb_info_loop()->
    receive
        {update_information, #information{id=_Id}=NewInfo} ->
            update_information_1(NewInfo),
            pdb_info_loop();
        {update_information_child, {Id, Child}} ->
            update_information_child_1(Id, Child),
            pdb_info_loop();
        {update_information_rq, {Pid, {TS,Rq}}} ->
            update_information_rq_1(Pid, {TS, Rq}),
            pdb_info_loop();
        {update_information_sent, {From, MsgSize, To, Ts}} ->
            update_information_sent_1(From, MsgSize, To, Ts),
            pdb_info_loop();
        {update_information_received, {Pid, MsgSize}} ->
            update_information_received_1(Pid, MsgSize),
            pdb_info_loop();       
        {update_information_element, {Key, {Pos, Value}}} ->
            ets:update_element(pdb_info, Key, {Pos, Value}),
            pdb_info_loop();
        {action,stop} ->
            ok
    end.

update_information_1(#information{id = Id} = NewInfo) ->
    case ets:lookup(pdb_info, Id) of
    	[] ->
            ets:insert(pdb_info, NewInfo),
	    ok;
	[Info] ->
	    % Remake NewInfo and Info to lists then substitute
	    % old values for new values that are not undefined or empty lists.
	    {_, Result} = lists:foldl(
	    	fun (InfoElem, {[NewInfoElem | Tail], Out}) ->
		    case NewInfoElem of
		    	undefined ->
			    {Tail, [InfoElem | Out]};
		    	[] ->
			    {Tail, [InfoElem | Out]};
                        {0,0} ->
                            {Tail, [InfoElem | Out]};
                        0 ->
                            {Tail, [InfoElem|Out]};
                        _ ->
			    {Tail, [NewInfoElem | Out]}
		    end
		end, {tuple_to_list(NewInfo), []}, tuple_to_list(Info)),
                     ets:insert(pdb_info, list_to_tuple(lists:reverse(Result)))
    end.

update_information_child_1(Id, Child) -> 
    case ets:lookup(pdb_info, Id) of
    	[] ->
            ets:insert(pdb_info,#information{
                         id = Id,
                         children = [Child]});
        [I] ->
            ets:insert(pdb_info,
                       I#information{
                         children = [Child|I#information.children]})
    end.

update_information_rq_1(Pid, {TS,RQ}) ->
    case ets:lookup(pdb_info, Pid) of
        [] -> 
            ets:insert(pdb_info, #information{
                         id = Pid, 
                         rq_history=[{TS,RQ}]}),
            ok; %% this should not happen;
        [I] ->
            ets:update_element(
              pdb_info, Pid, {9, [{TS, RQ}|I#information.rq_history]})
    end.

%% with the parallel version, checking whether a message is 
%% send to the same run queue needs a different algorithm,
%% and this feature is removed for now.
update_information_sent_1(From, MsgSize, To, Ts) ->
    update_inter_node_message_tab(From, MsgSize, To, Ts),
    case  ets:lookup(pdb_info, From) of
        [] -> 
            ets:insert(pdb_info, 
                       #information{id=From, 
                                    msgs_sent={1, MsgSize}
                                   });            
        [I] ->
            {No, Size} =  I#information.msgs_sent, 
            ets:update_element(pdb_info, From, 
                               {12, {No+1, Size+MsgSize}})
    end.

update_inter_node_message_tab(From, MsgSize, To, Ts) ->
    %% io:format("From To:\n~p\n", [{From, To}]),
    %% io:format("same node:~p\n", [same_node_pids(From, To)]),
    case same_node_pids(From, To) of
        true ->
            ok;
        false ->
            ets:insert(inter_node, 
                       #inter_node{
                         timed_from_node = {Ts, get_node_name(From)},
                         to_node=get_node_name(To),
                         msg_size = MsgSize})
    end.

  
update_information_received_1(Pid, MsgSize) ->
    case  ets:lookup(pdb_info, Pid) of
        [] -> 
            ets:insert(pdb_info, #information{
                         id =Pid,
                         msgs_received ={1, MsgSize}
                        });
        [I] ->
            {No, Size} = I#information.msgs_received,
            ets:update_element(pdb_info, Pid,
                               {11, {No+1, Size+MsgSize}})
    end.

select_query_information(Query) ->
    case Query of
    	{information, all} -> 
	    ets:select(pdb_info, [{
		#information{ _ = '_'},
		[],
		['$_']
		}]);
	{information, procs} ->
	    ets:select(pdb_info, [{
		#information{id = {pid,'$1'}, _ = '_'},
                [],
		['$_']
		}]);
        {information, procs_count} ->
             ets:select_count(pdb_info, [{
		#information{id = {pid, '$1'}, _ = '_'},
		[{is_pid, '$1'}],
		[true]
		}]);
	{information, ports} ->
	    ets:select(pdb_info, [{
		#information{ id = '$1', _ = '_'},
		[{is_port, '$1'}],
		['$_']
		}]);
        {information, ports_count} ->
	    ets:select_count(pdb_info, [{
		#information{ id = '$1', _ = '_'},
		[{is_port, '$1'}],
		[true]
		}]);
        {information, {range_min_max, Ids}} ->
            StartStopTS=[ets:select(pdb_info, 
                                    [{#information{id = Id, start='$2', stop='$3', _ = '_'},
                                      [],
                                      [{{'$2', '$3'}}]
                                     }])||Id<-Ids],
            [{_, SystemStartTs}] =ets:lookup(pdb_system, {system, start_ts}),
            [{_, SystemStopTs}] =ets:lookup(pdb_system, {system, stop_ts}),
            io:format("SystemStopstarts:\n~p\n", [{SystemStartTs, SystemStopTs}]),
            {Starts, Stops} = lists:unzip(lists:append(StartStopTS)),
            {lists:min(Starts), lists:max(Stops)};
        {information, Id} when is_port(Id) -> 
	    ets:select(pdb_info, [{
		#information{ id = Id, _ = '_'},
		[],
		['$_']
		}]);
        {information, Id={pid, _}} -> 
	    ets:select(pdb_info, [{
		#information{ id = Id, _ = '_'},
		[],
		['$_']
		}]);
	Unhandled ->
	    io:format("select_query_information, unhandled: ~p~n", [Unhandled]),
	    []
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             access to pdb_system                 %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
           
%% central pdb_system table shared by sub DBs.
init_pdb_system(ProcRegName, Parent)->  
    register(ProcRegName, self()),
    Parent ! {ProcRegName, started},
    pdb_system_loop().

update_system_start_ts(SystemProcRegName, TS) ->
    %% io:format("SysmteProcRegName:\n~p\n", [whereis(SystemProcRegName)]),
    SystemProcRegName ! {'update_system_start_ts', TS}.

update_system_stop_ts(SystemProcRegName, TS) ->
    SystemProcRegName ! {'update_system_stop_ts', TS}.

pdb_system_loop() ->
    receive
        {'update_system_start_ts', TS}->
            update_system_start_ts_1(TS),
            pdb_system_loop();
        {'update_system_stop_ts', TS} ->
            update_system_stop_ts_1(TS),
            pdb_system_loop();
        {action, stop} ->
            ok
    end.
    
update_system_start_ts_1(TS) ->
    case ets:lookup(pdb_system, {system, start_ts}) of
    	[] ->
	    ets:insert(pdb_system, {{system, start_ts}, TS});
	[{{system, start_ts}, StartTS}] ->
	    DT = ?seconds(StartTS, TS),
	    if 
		DT > 0.0 -> ets:insert(pdb_system, {{system, start_ts}, TS});
	    	true -> ok
	    end;
	Unhandled -> 
	    io:format("update_system_start_ts, unhandled ~p ~n", [Unhandled])
    end.
	
update_system_stop_ts_1(TS) ->
    case ets:lookup(pdb_system, {system, stop_ts}) of
    	[] ->
	    ets:insert(pdb_system, {{system, stop_ts}, TS});
	[{{system, stop_ts}, StopTS}] ->
	    DT = ?seconds(StopTS, TS),
	    if 
		DT < 0.0 -> ets:insert(pdb_system, {{system, stop_ts}, TS});
	  	true -> ok
	    end;
	Unhandled -> 
	    io:format("update_system_stop_ts, unhandled ~p ~n", [Unhandled])
    end.

%%% select_query_system
select_query_system(Query) ->
    case Query of
    	{system, start_ts} ->
    	    case ets:lookup(pdb_system, {system, start_ts}) of
	    	[] -> undefined;
		[{{system, start_ts}, StartTS}] -> StartTS
	    end;
    	{system, stop_ts} ->
    	    case ets:lookup(pdb_system, {system, stop_ts}) of
	    	[] -> undefined;
		[{{system, stop_ts}, StopTS}] -> StopTS
	    end;
	Unhandled ->
	    io:format("select_query_system, unhandled: ~p~n", [Unhandled]),
	    []
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             access to pdb_func                   %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init_pdb_func(ProcRegName, Parent) ->
    register(ProcRegName, self()),
    Parent !{ProcRegName, started},
    "pdb_func" ++ Index = atom_to_list(ProcRegName),
    pdb_func_loop({Parent, list_to_integer(Index), [], [], false}).

trace_call(SubDBIndex, Pid, Func, TS, CP) ->
    ProcRegName =mk_proc_reg_name("pdb_func", SubDBIndex),
    ProcRegName ! {trace_call, {Pid, Func, TS, CP}}.

trace_return_to(SubDBIndex,Pid, MFA, TS) ->
    ProcRegName =mk_proc_reg_name("pdb_func", SubDBIndex),
    ProcRegName !{trace_return_to, {Pid, MFA, TS}}.

%% one pdb_func_loop for each trace file.
pdb_func_loop({SubDB, SubDBIndex, ChildrenProcs, PrevStacks, Done}) ->
    receive
        CallTrace={trace_call, {Pid, _, _, _}} ->
            case lists:keyfind(Pid, 1, ChildrenProcs) of 
                {Pid, Proc} ->
                    Proc ! CallTrace,
                    pdb_func_loop({SubDB, SubDBIndex, ChildrenProcs, PrevStacks, Done});
                false ->
                    PrevStack = case lists:keyfind(Pid,1,PrevStacks) of 
                                    false -> false;
                                    {Pid, Stack} -> Stack
                                end,
                    Proc = spawn_link(
                             fun()-> 
                                     pdb_sub_func_loop({SubDBIndex, Pid, [], PrevStack, 0})
                             end),
                    Proc! CallTrace,
                    pdb_func_loop({SubDB, SubDBIndex,[{Pid, Proc}|ChildrenProcs], PrevStacks, Done})                        
            end;
        ReturnTrace={trace_return_to, {Pid, _, _}} ->
            case lists:keyfind(Pid, 1, ChildrenProcs) of 
                {Pid, Proc} ->
                    Proc! ReturnTrace,
                    pdb_func_loop({SubDB, SubDBIndex, ChildrenProcs,PrevStacks, Done});
                false ->
                    PrevStack = case lists:keyfind(Pid,1,PrevStacks) of 
                                    false -> false;
                                    {Pid, Stack} -> Stack
                                end,
                    Proc = spawn_link(
                             fun()-> 
                                     pdb_sub_func_loop({SubDBIndex, Pid, [], PrevStack, 0})
                             end),
                    Proc! ReturnTrace,
                    pdb_func_loop({SubDB, SubDBIndex,[{Pid, Proc}|ChildrenProcs],PrevStacks, Done})
            end;
        %% the current file file get to the end.
        {_Parent, end_of_trace_file} ->
            Self = self(),
            [Proc!{Self, end_of_trace_file}
             ||{_, Proc}<-ChildrenProcs],
            NextFuncRegName = mk_proc_reg_name("pdb_func", SubDBIndex+1),
            case whereis(NextFuncRegName) of 
                undefined -> ok;
                NextPid ->
                    [NextPid ! {end_of_trace_file, {SubDBIndex, Pid, Stack}}
                     ||{Pid, Stack}<-PrevStacks]
            end,
            pdb_func_loop({SubDB, SubDBIndex,ChildrenProcs,[], true});
        {Pid, done} ->
           %%  io:format("One Proc done: ~p\n", [{Pid, SubDBIndex}]),
          %% %%  io:format("Childrenprocs:\n~p\n", [ChildrenProcs]),
            case lists:keydelete(Pid,1,ChildrenProcs) of
                [] ->
                    %% io:format("All procs are done. SubdbIndex:~p\n", [{SubDB, SubDBIndex}]),
                    SubDB ! {SubDBIndex,done},
                    pdb_func_loop({SubDB, SubDBIndex,[], [], Done});
                NewChildrenProcs ->
                    pdb_func_loop({SubDB, SubDBIndex, lists:keydelete(Pid, 1, NewChildrenProcs),
                                   lists:keydelete(Pid, 1, PrevStacks), Done})
            end;
        %% a process parsing the previous log file gets to the end
        {end_of_trace_file, {PrevSubDBIndex,Pid, Stack}} ->
           %% io:format("Received stack from privious subdb:~p\n",[{PrevSubDBIndex,Pid, Stack}]),
            case lists:keyfind(Pid, 1, ChildrenProcs) of 
                {Pid, Proc} ->
                    Proc ! {end_of_trace_file, {PrevSubDBIndex, Pid, Stack}},
                    pdb_func_loop({SubDB, SubDBIndex,ChildrenProcs,PrevStacks, Done});
                false when Done->
                    NextFuncRegName = mk_proc_reg_name("pdb_func", SubDBIndex+1),
                    case whereis(NextFuncRegName) of 
                        undefined -> ok;
                        NextPid ->
                            NextPid ! {end_of_trace_file, {SubDBIndex, Pid, Stack}}
                    end,
                    %% io:format("Pid proc does not exist\n"), 
                    pdb_func_loop({SubDB, SubDBIndex, ChildrenProcs, PrevStacks, Done});
                false ->
                    %% This could be that the process has not run yet, or the process 
                    %% has finished.
                    pdb_func_loop({SubDB, SubDBIndex, ChildrenProcs, [{Pid, Stack}|PrevStacks], Done})
            end;
        Others -> 
            io:format("Unexpected message:~p\n", [Others]),
            pdb_func_loop({SubDB,SubDBIndex,ChildrenProcs, PrevStacks, Done})                
    end.

pdb_sub_func_loop({SubDBIndex,Pid, Stack, PrevStack, WaitTimes}) ->
    receive
        {trace_call, {Pid, Func, TS, CP}} ->
            NewStack=trace_call_1(Pid, Func, TS, CP, Stack),
            pdb_sub_func_loop({SubDBIndex, Pid, NewStack, PrevStack, WaitTimes});
        {trace_return_to, {Pid, Func, TS}} ->
            PrevSubIndex = SubDBIndex-1,
            case trace_return_to_1(Pid, Func, TS, Stack) of
                wait_for_prev_stack ->
                    case SubDBIndex of 
                        1 ->
                            Stack1=[[{Func, TS}]],
                            pdb_sub_func_loop({SubDBIndex, Pid, Stack1, PrevStack, WaitTimes+1});
                        _ ->
                            case PrevStack of 
                                false ->
                                    %% io:format("Wait times:~p\n", [WaitTimes]),
                                    %% io:format("wait for prev stack:~p\n", [{PrevSubIndex, Pid, WaitTimes}]),
                                    receive 
                                        {end_of_trace_file, {PrevSubIndex, Pid, PrevStack1}} ->
                                          %%  io:format("received previous stack:~p\n", [{PrevSubIndex, Pid, PrevStack1}]),
                                            NewStack1=trace_return_to_1(Pid, Func, TS, PrevStack1),
                                            pdb_sub_func_loop({SubDBIndex, Pid, NewStack1, false, WaitTimes+1})
                                    %% after 50000 ->
                                    %%         io:format("Time out ~p\n", [{PrevSubIndex, Pid, WaitTimes}]),
                                    %%         pdb_sub_func_loop({SubDBIndex, Pid, [[{Func, TS}]], false, WaitTimes+1})
                                    end;
                                _ ->
                                    NewStack1=trace_return_to_1(Pid, Func, TS, PrevStack),
                                    pdb_sub_func_loop({SubDBIndex, Pid, NewStack1, false, WaitTimes+1})
                            end
                    end;
                NewStack ->
                    pdb_sub_func_loop({SubDBIndex, Pid, NewStack, PrevStack, WaitTimes})
            end;
        {Parent, end_of_trace_file} ->
            NextFuncRegName = mk_proc_reg_name("pdb_func",SubDBIndex+1),
          %%  io:format("SubDB: ~p Process ~p done\n", [SubDBIndex, Pid]),
            case whereis(NextFuncRegName) of 
                undefined ->
                  %%  io:format("NewFuncRegName ~p does not exist\n", [NextFuncRegName]),
                    Parent ! {Pid, done};
                NextPid ->
                   %% io:format("End of trace Stack:\n~p\n", [Stack]),
                    NextPid ! {end_of_trace_file, {SubDBIndex, Pid, Stack}},
                    Parent ! {Pid, done}
            end
    end.

mk_proc_reg_name(RegNamePrefix,Index) ->
    list_to_atom(RegNamePrefix ++ integer_to_list(Index)).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             trace function call                  %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
trace_call_1(Pid, MFA, TS, CP, Stack) ->
    Func = mfarity(MFA),
    ?dbg(0, "trace_call(~p, ~p, ~p, ~p, ~p)~n", 
	 [Pid, Stack, Func, TS, CP]),
    case Stack of 
        [[{Func1,TS1}, dummy]|Stack1] when Func1=/=CP ->
            {Caller1, Caller1StartTs}= case Stack1 of 
                                           [[{Func2, TS2}|_]|_]->
                                               {Func2, TS2};
                                           _ ->
                                               {Func1, TS1}
                                       end,
            update_calltree_info(Pid, {Func1, TS1, TS}, {Caller1, Caller1StartTs}),
            trace_call_2(Pid, Func, TS, CP, Stack1);
        _ ->
            trace_call_2(Pid, Func, TS, CP, Stack)
    end.
    
trace_call_2(Pid, Func, TS, CP, Stack) ->
    case Stack of
	[] ->
            ?dbg(0, "empty stack\n", []),
            OldStack = 
		if CP =:= undefined ->
			Stack;
		   true ->
			[[{CP, TS}]]
		end,
            [[{Func, TS}] | OldStack];
        [[{suspend, _} | _] | _] ->
      	    throw({inconsistent_trace_data, ?MODULE, ?LINE,
                   [Pid, Func, TS, CP, Stack]});
	[[{garbage_collect, _} | _] | _] ->
	    throw({inconsistent_trace_data, ?MODULE, ?LINE,
                   [Pid, Func, TS, CP, Stack]});
        [[{Func, _FirstInTS}]] ->
            Stack;
        [[{CP, _} | _], [{CP, _} | _] | _] ->
            trace_call_shove(Pid,Func, TS, Stack);
        [[{CP, _} | _] | _] when Func==CP ->
            ?dbg(0, "Current function becomes new stack top.\n", []),
            Stack;
	[[{CP, _} | _] | _] ->
            ?dbg(0, "Current function becomes new stack top.\n", []),
            [[{Func, TS}] | Stack];
        [_, [{CP, _} | _] | _] ->
           ?dbg(0, "Stack top unchanged, no push.\n", []),
           trace_call_shove(Pid, Func, TS, Stack); 
        [[{Func0, _} | _], [{Func0, _} | _], [{CP, _} | _] | _] ->
            trace_call_shove(Pid, Func, TS,
                             trace_return_to_2(Pid, Func0, TS,
                                               Stack));
        [_|_] ->
           [[{Func, TS}], [{CP, TS}, dummy]|Stack]
    end.
    
%% Tail recursive stack push
trace_call_shove(_Pid, Func, TS, []) ->
    [[{Func, TS}]];
trace_call_shove(Pid, Func, TS,  [Level0|Stack1]) ->
    [[{Func1,TS1}| NewLevel0] | NewStack1] = 
        [trace_call_collapse([{Func, TS} | Level0]) | Stack1],
    case Level0 -- [{Func1,TS1}| NewLevel0] of 
        [] -> ok;
        Funs ->
            {Caller1, Caller1StartTs}= hd(NewLevel0),
            [update_calltree_info(Pid, {Func2, TS2, TS}, {Caller1, Caller1StartTs})||
                     {Func2, TS2} <- Funs]
    end,
    [[{Func, TS1} | NewLevel0] | NewStack1].
    
 
%% Collapse tail recursive call stack cycles to prevent them from
%% growing to infinite length.
trace_call_collapse([]) ->
    [];
trace_call_collapse([_] = Stack) ->
    Stack;
trace_call_collapse([_, _] = Stack) ->
     Stack;
trace_call_collapse([_ | Stack1] = Stack) ->
    ?dbg(0, "collapse_trace_state(~p)~n", [Stack]),
    trace_call_collapse_1(Stack, Stack1, 1).


%% Find some other instance of the current function in the call stack
%% and try if that instance may be used as stack top instead.
trace_call_collapse_1(Stack, [], _) ->
    Stack;
trace_call_collapse_1([{Func0, _} | _] = Stack, [{Func0, _} | S1] = S, N) ->
    case trace_call_collapse_2(Stack, S, N) of
	true ->
	    S;
	false ->
	    trace_call_collapse_1(Stack, S1, N+1)
    end;
trace_call_collapse_1(Stack, [_ | S1], N) ->
    trace_call_collapse_1(Stack, S1, N+1).

%% Check if all caller/called pairs in the perhaps to be collapsed
%% stack segment (at the front) are present in the rest of the stack, 
%% and also in the same order.
trace_call_collapse_2(_, _, 0) ->
    true;
trace_call_collapse_2([{Func1, _} | [{Func2, _} | _] = Stack2],
	   [{Func1, _} | [{Func2, _} | _] = S2],
	   N) ->
    trace_call_collapse_2(Stack2, S2, N-1);
trace_call_collapse_2([{Func1, _} | _], [{Func1, _} | _], _N) ->
    false;
trace_call_collapse_2(_Stack, [_], _N) ->
    false;
trace_call_collapse_2(Stack, [_ | S], N) ->
    trace_call_collapse_2(Stack, S, N);
trace_call_collapse_2(_Stack, [], _N) ->
    false.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%             trace function return                %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
trace_return_to_1(Pid, Func, TS, Stack) ->
    Caller = mfarity(Func),
    ?dbg(0, "trace_return_to(~p, ~p, ~p)~n~p~n", 
	 [Pid, Caller, TS, Stack]),
    case Stack of
	[[{suspend, _} | _] | _] ->
	    throw({inconsistent_trace_data, ?MODULE, ?LINE,
                   [Pid, Caller, TS, Stack]});
	[[{garbage_collect, _} | _] | _] ->
	    throw({inconsistent_trace_data, ?MODULE, ?LINE,
                   [Pid, Caller, TS, Stack]});
        [_, [{Caller, _}|_]|_] ->
            trace_return_to_2(Pid, Caller, TS, Stack);
        [[{Func1, TS1}, dummy]|Stack1=[_, [{Caller, _}|_]]] when Caller=/=Func1->
            {Caller1, Caller1StartTs}= 
                case Stack1 of 
                    [[{Func2, TS2}|_]|_]->
                        {Func2, TS2};
                    _ ->
                        {Func1, TS1}
                end,
            update_calltree_info(Pid, {Func1, TS1, TS}, {Caller1, Caller1StartTs}),
            trace_return_to_2(Pid, Caller, TS, Stack);
        _ when Caller == undefined ->
            trace_return_to_2(Pid, Caller, TS, Stack);
        [] ->
            wait_for_prev_stack;
        _ ->
            {Callers,_} = lists:unzip([hd(S)||S<-Stack]),
            case lists:member(Caller, Callers) of
                true ->
                    trace_return_to_2(Pid, Caller, TS, Stack);
                _ -> 
                    [[{Caller, TS}, dummy]|Stack]
            end
    end.

trace_return_to_2(_, undefined, _, []) ->
    [];
trace_return_to_2(_Pid, _Func, _TS, []) ->
    wait_for_prev_stack;
    %%[[{Func, TS}]];
trace_return_to_2(Pid, Func, TS, [[] | Stack1]) ->
    trace_return_to_2(Pid, Func, TS, Stack1);
trace_return_to_2(_Pid, Func, _TS, [[{Func, _}|_Level0]|_Stack1] = Stack) ->
    Stack;
trace_return_to_2(Pid, Func, TS, [[{Func0, TS1} | Level1] | Stack1]) ->
    case Func0 of 
         {_, _, _} ->
            {Caller, CallerStartTs}= case Level1 of 
                                         [{Func1, TS2}|_] ->
                                             {Func1, TS2};
                                         _ -> case Stack1 of 
                                                  [[{Func1, TS2}, dummy]|_] ->
                                                      {Func1, TS2};
                                                  [[{Func1, TS2}|_]|_]->
                                                      {Func1, TS2};
                                                  [] ->
                                                      {Func, TS1}
                                              end
                                     end,
            ets:insert(funcall_info, #funcall_info{id={Pid, TS1}, func=Func0, end_ts=TS}),
            update_fun_call_count_time({Pid, Func0}, {TS1, TS}),
            update_calltree_info(Pid, {Func0, TS1, TS}, {Caller, CallerStartTs});
         _ -> ok  %% garbage collect or suspend.
    end,
    if Level1 ==[dummy] ->
            trace_return_to_2(Pid, Func, TS, Stack1);
       true ->
            trace_return_to_2(Pid, Func, TS, [Level1|Stack1])
    end.
   
        
update_calltree_info(Pid, {Callee, StartTS0, EndTS}, {Caller, CallerStartTS0}) ->
    CallerStartTS = case is_list_comp(Caller) of 
                       true -> undefined;
                       _ -> CallerStartTS0
                   end,
    StartTS = case is_list_comp(Callee) of 
                   true -> undefined;
                   _ -> StartTS0
               end,
    Pid1 = percept2_utils:pid2value(Pid),
    case ets:lookup(fun_calltree, {Pid1, Callee, StartTS}) of
        [] ->
            add_new_callee_caller(Pid1, {Callee, StartTS, EndTS},
                                  {Caller, CallerStartTS});
        [F] -> 
            NewF =F#fun_calltree{id=setelement(3, F#fun_calltree.id, Caller),
                                 cnt=1,
                                 start_ts =StartTS,
                                 end_ts=EndTS},                  
            case ets:lookup(fun_calltree, {Pid1, Caller, CallerStartTS}) of 
                [C] when Caller=/=Callee->
                    ets:delete_object(fun_calltree, F),
                    NewC = C#fun_calltree{called=add_new_callee(NewF, C#fun_calltree.called)},
                    NewC1 = collapse_call_tree(NewC, Callee),
                    ets:insert(fun_calltree, NewC1);                  
                _ ->
                    CallerInfo = #fun_calltree{id = {Pid1, Caller, CallerStartTS},
                                               cnt =1,
                                               start_ts=CallerStartTS,
                                               called = [NewF]}, 
                    ets:delete_object(fun_calltree, F),
                    NewCallerInfo = collapse_call_tree(CallerInfo, Callee),
                    ets:insert(fun_calltree, NewCallerInfo)
            end
    end.

add_new_callee_caller(Pid, {Callee, StartTS, EndTS},{Caller, CallerStartTS}) ->
    CalleeInfo = #fun_calltree{id={Pid, Callee, Caller},
                               cnt =1, 
                               called = [],
                               start_ts = StartTS,
                               end_ts = EndTS},
    case ets:lookup(fun_calltree, {Pid, Caller, CallerStartTS}) of
         [] ->
            CallerInfo = #fun_calltree{id = {Pid, Caller, CallerStartTS},
                                       cnt =1,
                                       called = [CalleeInfo],
                                       start_ts=CallerStartTS},
            ets:insert(fun_calltree, CallerInfo);
        [C] ->
            NewC = C#fun_calltree{called=add_new_callee(CalleeInfo, C#fun_calltree.called)},
            ets:insert(fun_calltree, NewC)
    end.


%% collapse recursive call chains to which Callee is an element of 
%% recursion.      
%% TOTest: is this accurate enough?
collapse_call_tree(CallTree, Callee) ->
    {_Pid, Caller,_TS} = CallTree#fun_calltree.id,
    Children=CallTree#fun_calltree.called,
    case collect_children_to_merge(Children, {Caller, Callee}) of 
        {_, []} ->
         %%   io:format("Nothing to merge\n"),
            CallTree;
        {ToRemain, ToMerge} ->
            NewCalled = lists:foldl(fun(C, Acc) ->
                                             add_new_callee(C, Acc)
                                    end, ToRemain, ToMerge),
            CallTree#fun_calltree{called=NewCalled}
            
    end.

collect_children_to_merge([], _) ->       
    {[], []};
collect_children_to_merge(CallTrees, {Caller, Callee}) ->
    {ToRemain, ToMerge}=lists:unzip(
                          [collect_children_to_merge_1(CallTree,{Caller,Callee})
                           ||CallTree <- CallTrees]),
    {ToRemain, lists:append(ToMerge)}.

collect_children_to_merge_1(CallTree, {Caller, Callee}) ->
    {_Pid, MFA, _TS}=CallTree#fun_calltree.id,
    case MFA of 
        Caller ->
            Called = CallTree#fun_calltree.called,
            {ToMerge, ToRemain}=lists:partition(
                                  fun(F)->
                                          element(2, F#fun_calltree.id)==Callee
                                  end, Called),
            {CallTree#fun_calltree{called=ToRemain}, ToMerge};
        _ ->
            {ToRemain, ToMerge}=collect_children_to_merge(
                                  CallTree#fun_calltree.called, {Caller, Callee}),
            {CallTree#fun_calltree{called=ToRemain}, ToMerge}
    end.

add_new_callee(CalleeInfo, CalleeList) ->
    Id = CalleeInfo#fun_calltree.id,
  %%  io:format("ID:\n~p\n", [Id]),
    case lists:keyfind(Id, 2, CalleeList) of
        false ->
          %%  io:format("not found\n"),
            [CalleeInfo|CalleeList];
        C ->
           %% io:format("found:~p\n", [C]),
            NewC=combine_fun_info(C, CalleeInfo),
            lists:keyreplace(Id, 2, CalleeList, NewC)
    end.

combine_fun_info(FunInfo1=#fun_calltree{id=Id, called=Callees1, 
                                        start_ts=StartTS1,end_ts= _EndTS1,
                                        cnt=CNT1}, 
                 _FunInfo2=#fun_calltree{id=Id, called=Callees2, 
                                         start_ts=_StartTS2, end_ts=EndTS2,
                                         cnt=CNT2}) ->
    NewCallees=lists:foldl(fun(C, Callees) ->
                                  add_new_callee(C, Callees)
                           end, Callees1, Callees2),
    FunInfo1#fun_calltree{id=Id, called=NewCallees, 
                      start_ts=StartTS1, end_ts=EndTS2,
                      cnt = CNT1 + CNT2}.
                      
is_list_comp({_M, F, _A}) ->
    re:run(atom_to_list(F), ".*-lc.*", []) /=nomatch;
is_list_comp(_) ->
    false.
      

%%%---------------------------%%%
%%%                           %%%
%%%     consolidate db        %%%
%%%                           %%%
%%%---------------------------%%%
%% consolidate_db() -> bool()
%% Purpose:
%%	Check start/stop time
%%	Activity consistency
%%      function call tree, and
%%      generate function inforation.

-spec consolidate_db([{filename(), pid()}]) ->boolean().
consolidate_db(FileNameSubDBPairs) ->
    io:format("Consolidating...~n"),
    LastIndex = length(FileNameSubDBPairs),
    % Check start/stop timestamps
    case percept_db_select_query([], {system, start_ts}) of
	undefined ->
            Min=get_start_time_ts(),
            update_system_start_ts(mk_proc_reg_name("pdb_system", 1),Min);
        _ -> ok
    end,
    case percept_db_select_query([], {system, stop_ts}) of
	undefined ->
            Max = get_stop_time_ts(LastIndex),
            update_system_stop_ts(mk_proc_reg_name("pdb_system", 1),Max);
        _ -> ok
    end,
    io:format("consolidate runnability ...\n"),
    consolidate_runnability(LastIndex),
    io:format("consolidate function callgraph ...\n"),
    consolidate_calltree(),
    io:format("generate function information ...\n"),
    process_func_info(),
    true.

get_start_time_ts() ->
    AMin = case ets:first(pdb_activity1) of 
               T when is_tuple(T)-> T;
               _ ->undefined
           end,
    SMin =case ets:first(pdb_scheduler1) of 
              T1 when is_tuple(T1)-> T1;
               _ -> undefined
          end,
    IMin =case ets:first(inter_node) of 
              {T2, _} when is_tuple(T2)-> T2;
              _ -> undefined
          end,
    Ts = [T||T<-[AMin, SMin, IMin], T/=undefined],
    io:format("Ts:\n~p\n", [[AMin, SMin, IMin]]),
    case Ts of
        [] -> undefined;
        _ -> lists:min(Ts)
    end.

get_stop_time_ts(LastIndex) ->
    LastIndex1 = integer_to_list(LastIndex),
    LastActTab =list_to_atom("pdb_activity"++LastIndex1),
    LastSchedulerTab= list_to_atom("pdb_scheduler"++LastIndex1),
    AMax = case ets:last(LastActTab) of 
               T when is_tuple(T)-> T;
               _ ->undefined
           end,
    SMax = case ets:last(LastSchedulerTab) of 
               T1 when is_tuple(T1)-> T1;
               _ -> undefined
           end,
    IMax =case ets:last(inter_node) of 
              {T2, _} when is_tuple(T2)-> T2;
              _ -> undefined
          end,
    Ts = [T||T<-[AMax, SMax, IMax], T/=undefined],
    case Ts of
        [] -> undefined;
        _ -> lists:max(Ts)
    end.
  
    
%%%------------------------------------------------------%%%
%%%                                                      %%%
%%%  consolidate runnability                             %%%
%%%                                                      %%%
%%%------------------------------------------------------%%%
consolidate_runnability(LastSubDBIndex) ->
    io:format("LastSubDBIndex:\n~p\n", [LastSubDBIndex]),
    consolidate_runnability_1(1,{0,0,[]},LastSubDBIndex).

consolidate_runnability_1(CurSubDBIndex, _, LastSubDBIndex) 
  when CurSubDBIndex>LastSubDBIndex ->
    ok;
consolidate_runnability_1(CurSubDBIndex, {ActiveProcs, ActivePorts, RunnableStates},
                          LastSubDBIndex) ->
    ActivityProcRegName = mk_proc_reg_name("pdb_activity", CurSubDBIndex),
    Pid = whereis(ActivityProcRegName),
    Pid ! {consolidate_runnability, 
           {self(), CurSubDBIndex, {ActiveProcs, ActivePorts, RunnableStates}}},
    receive
        {Pid,done, {NewActiveProcs, NewActivePorts, NewRunnableStates}} ->
            consolidate_runnability_1(CurSubDBIndex+1, 
                                      {NewActiveProcs, NewActivePorts, NewRunnableStates},
                                      LastSubDBIndex)
    end.

%%%------------------------------------------------------%%%
%%%                                                      %%%
%%%  consolidate calltree to make sure each process only %%%
%%   has one calltree.                                   %%%
%%%                                                      %%%
%%%------------------------------------------------------%%%
consolidate_calltree() ->
    Pids=ets:select(fun_calltree, 
                    [{#fun_calltree{id = {'$1', '_','_'}, _='_'},
                      [],
                      ['$1']
                     }]),
    case Pids -- lists:usort(Pids) of 
        [] ->  %%  each process only has one calltree, the ideal case.
            ok; 
        Pids1->
            consolidate_calltree_1(lists:usort(Pids1))
    end.
             
consolidate_calltree_1(Pids) ->
    lists:foreach(fun(Pid) ->
                          consolidate_calltree_2(Pid)
                  end, Pids).
consolidate_calltree_2(Pid) ->
    [Tree|Others]=ets:select(fun_calltree, 
                             [{#fun_calltree{id = {Pid, '_','_'}, _='_'},
                               [],
                               ['$_']
                              }]),
    Key = Tree#fun_calltree.id,
    ets:update_element(fun_calltree, Key, {4, Others++Tree#fun_calltree.called}),
    lists:foreach(fun(T)-> 
                          ets:delete_object(fun_calltree, T) 
                  end, Others).


%%%------------------------------------------------------%%%
%%%                                                      %%%
%%%  Generate statistic information about each function. %%%
%%%                                                      %%%
%%%------------------------------------------------------%%%
process_func_info() ->
    Ids=ets:select(fun_calltree, 
                   [{#fun_calltree{id = '$1', _='_'},
                     [], ['$1']}]),
    percept2_utils:pforeach(
      fun(Id) -> 
              process_a_call_tree(Id) 
      end, Ids),
    ok.
process_a_call_tree(Id) ->
    [Tree]=ets:lookup(fun_calltree, Id),
    process_a_call_tree_1(Tree).    

process_a_call_tree_1(CallTree) ->
    {Pid, MFA, Caller}=CallTree#fun_calltree.id,
    case MFA of 
        undefined ->
            Children=CallTree#fun_calltree.called,
            [process_a_call_tree_1(C)||C <- Children];
        _ ->
            update_fun_info({Pid, MFA}, 
                             {Caller, CallTree#fun_calltree.cnt},
                             [{element(2, C#fun_calltree.id),
                               C#fun_calltree.cnt}
                              ||C <- CallTree#fun_calltree.called],
                             CallTree#fun_calltree.start_ts,
                             CallTree#fun_calltree.end_ts),                             
            Children=CallTree#fun_calltree.called,
            [process_a_call_tree_1(C)||C <- Children]
    end.

      
update_fun_call_count_time({Pid, Func}, {StartTs, EndTs}) ->
    Time = ?seconds(EndTs, StartTs),
    case ets:lookup(fun_info, {Pid, Func}) of 
        [] ->
            ets:insert(fun_info, #fun_info{id={percept2_utils:pid2value(Pid), Func},
                                           call_count=1, 
                                           acc_time=Time});
        [FunInfo] ->
            ets:update_element(fun_info, {percept2_utils:pid2value(Pid), Func},
                               [{7, FunInfo#fun_info.call_count+1},
                                {8, FunInfo#fun_info.acc_time+Time}])
    end.

update_fun_info({Pid, MFA}, Caller, Called, StartTs, EndTs) ->
    case ets:lookup(fun_info, {Pid, MFA}) of
        [] ->
            NewEntry=#fun_info{id={percept2_utils:pid2value(Pid), MFA},
                               callers = [Caller],
                               called = Called,
                               start_ts= StartTs, 
                               end_ts = EndTs},
            ets:insert(fun_info, NewEntry);
        [FunInfo] ->
            NewFunInfo=
                FunInfo#fun_info{
                  callers=add_to([Caller],
                                 FunInfo#fun_info.callers),
                  called = add_to(Called,FunInfo#fun_info.called),
                  start_ts = lists:min([FunInfo#fun_info.start_ts,StartTs]),
                  end_ts = lists:max([FunInfo#fun_info.end_ts,EndTs])},
            ets:insert(fun_info, NewFunInfo)
    end.

add_to(FunCNTPairs, Acc) ->
    lists:foldl(fun({Fun, CNT},Out) ->
                        add_to_1({Fun, CNT}, Out)
                end, Acc, FunCNTPairs).
add_to_1({Fun, CNT}, Acc) ->
    case lists:keyfind(Fun, 1, Acc) of 
        false ->
            [{Fun, CNT}|Acc];
        {Fun, CNT1} ->
            lists:keyreplace(Fun, 1, Acc, {Fun, CNT+CNT1})
    end.
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                  %%
%%   Generate process tree                          %%
%%                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type process_tree()::{#information{},[process_tree()]}.
gen_compressed_process_tree()->
    Trees = gen_process_tree(),
    put(last_index, 0),
    NewTrees=compress_process_tree(Trees),
    erase(last_index),
    NewTrees.

-spec gen_process_tree/0::()->[process_tree()].
gen_process_tree() ->
    Res = select({information,procs}),
    List = lists:keysort(2,Res),  
    gen_process_tree(List, []).

-spec gen_process_tree/2::([#information{}], [process_tree()]) 
                          -> [process_tree()].
gen_process_tree([], Out) ->
    add_ancestors(Out);
gen_process_tree([Elem|Tail], Out) ->
    Children = Elem#information.children,
    {ChildrenElems, Tail1} = lists:partition(
                               fun(E) -> 
                                       lists:member(E#information.id, 
                                                    [percept2_utils:pid2value(Pid)||Pid <- Children])
                               end, Tail),
    {NewChildren, NewTail}=gen_process_tree_1(ChildrenElems, Tail1, []),
    gen_process_tree(NewTail, [{Elem, NewChildren}|Out]).

-spec gen_process_tree_1/3::([#information{}], [#information{}],[process_tree()]) 
                          -> {[process_tree()], [#information{}]}.
gen_process_tree_1([], Tail, NewChildren) ->
    {NewChildren, Tail};
gen_process_tree_1([C|Cs], Tail, Out) ->
    Children = C#information.children,
    {ChildrenElems, Tail1} = lists:partition(
                               fun(E) -> 
                                       lists:member(E#information.id, 
                                                    [percept2_utils:pid2value(Pid)||Pid <- Children])
                               end, Tail),                           
    {NewChildren, NewTail}=gen_process_tree_1(ChildrenElems, Tail1, []),
    gen_process_tree_1(Cs, NewTail, [{C, NewChildren}|Out]).

-spec add_ancestors/1::(process_tree())->process_tree().
add_ancestors(ProcessTree) ->
    add_ancestors(ProcessTree, []).

add_ancestors(ProcessTree, As) ->
    [begin 
         update_information_element(pdb_info1, Parent#information.id, {8, As}),
         {Parent#information{ancestors=As},         
          add_ancestors(Children, [Parent#information.id|As])}
     end
     ||{Parent, Children} <- ProcessTree].

%%% -------------------	---%%%
%%% compress process tree  %%%
%%% -----------------------%%%

compress_process_tree(Trees) ->
    compress_process_tree(Trees, []).
  

compress_process_tree([], Out)->
    lists:reverse(Out);
compress_process_tree([T={P, _}|Ts], Out) ->
    case is_dummy_process_pid(P#information.id) of
        true ->
            compress_process_tree(Ts, Out);
        false ->
            T1=compress_process_tree_1(T),
            compress_process_tree(Ts, [T1|Out])
    end.

compress_process_tree_1(Tree={_Parent, []}) ->
    Tree;
compress_process_tree_1(_Tree={Parent, Children}) ->
    CompressedChildren = compress_process_tree_2(Children),
    {Parent, CompressedChildren}.

compress_process_tree_2(Children) when length(Children)<3->
    compress_process_tree(Children);
compress_process_tree_2(Children) ->
    GroupByEntryFuns=group_by(
                       1, 
                       [{mfarity(C1#information.entry), {C1,  C2}}
                        ||{C1,C2}<-Children]),
    Res=[compress_process_tree_3(ChildrenGroup)||
            ChildrenGroup<-GroupByEntryFuns],
    lists:sort(fun({T1, _}, {T2, _}) -> 
                       T1#information.start > T2#information.start 
               end, lists:append(Res)).

compress_process_tree_3(ChildrenGroup) ->
    {[EntryFun|_], Children=[C={C0,_}|Cs]} =
        lists:unzip(ChildrenGroup),
    case length(Children) <3 of 
        true -> 
            compress_process_tree(Children);
        false ->
            UnNamedProcs=[C1#information.id||
                             {C1,_}<-Children, 
                             C1#information.name==undefined],
            case length(UnNamedProcs) == length(Children) of
                true ->
                    Num = length(Cs),
                    LastIndex = get(last_index),
                    put(last_index, LastIndex+1),
                    CompressedChildren=
                        Info=#information{id={pid, {0,0,LastIndex}},
                                          name=list_to_atom(integer_to_list(Num)++" procs omitted"),
                                          parent=C0#information.parent,
                                          entry = EntryFun,
                                          start =lists:min([C1#information.start||{C1,_}<-Cs]),
                                          stop = lists:max([C1#information.stop||{C1, _}<-Cs]),
                                          msgs_received=lists:foldl(fun({P,_}, {R1Acc, R2Acc}) ->
                                                                           {R1, R2}=P#information.msgs_received,
                                                                           {R1+R1Acc, R2+R2Acc}
                                                                   end, {0,0}, Cs),
                                          msgs_sent = lists:foldl(fun({P, _}, {S1Acc, S2Acc}) ->
                                                                         {S1, S2} = P#information.msgs_sent,
                                                                         {S1+S1Acc, S2+S2Acc}
                                                                 end, {0,0}, Cs),
                                          hidden_pids = UnNamedProcs
                                         },
                    update_information_1(Info),
                    [compress_process_tree_1(C), {CompressedChildren,[]}];   
                false ->
                    compress_process_tree(Children)
            end
    end.

is_dummy_process_pid({pid, {0, 0, _}}) -> true;
is_dummy_process_pid(_) -> false.
     
%%% -------------------	%%%
%%% Utility functionss	%%%
%%% -------------------	%%%
        
mfarity({M, F, Args}) when is_list(Args) ->
    {M, F, length(Args)};
mfarity(MFA) ->
    MFA.

mfa2informative({erlang, apply, [M, F, Args]})  -> mfa2informative({M, F,Args});
mfa2informative({erlang, apply, [Fun, Args]}) ->
    FunInfo = erlang:fun_info(Fun), 
    M = case proplists:get_value(module, FunInfo, undefined) of
	    []        -> undefined_fun_module;
	    undefined -> undefined_fun_module;
	    Module    -> Module
	end,
    F = case proplists:get_value(name, FunInfo, undefined) of
	    []        -> 
                undefined_fun_function;
	    undefined -> 
                undefined_fun_function; 
	    Function  -> Function
	end,
    mfa2informative({M, F, Args});
mfa2informative(Mfa) -> Mfa.
     
 
group_by(N, TupleList) ->
    SortedTupleList = lists:keysort(N, lists:sort(TupleList)),
    group_by(N, SortedTupleList, []).

group_by(_N,[],Acc) -> Acc;
group_by(N,TupleList = [T| _Ts],Acc) ->
    E = element(N,T),
    {TupleList1,TupleList2} = 
	lists:partition(fun (T1) ->
				element(N,T1) == E
			end,
			TupleList),
    group_by(N,TupleList2,Acc ++ [TupleList1]).

%% fprof:apply(refac_sim_code_par_v0,sim_code_detection, [["c:/cygwin/home/hl/demo"], 5, 40, 2, 4, 0.8, ["c:/cygwin/home/hl/demo"], 8]). 

%% percept_profile:start({ip, 4711}, {refac_sim_code_par_v4,sim_code_detection, [["c:/cygwin/home/hl/percept/test"], 5, 40, 2, 4, 0.8, ["c:/cygwin/home/hl/percept/test"], 8]}, [])  

%%percept_profile:start({file, "sim_code_v0.dat"}, {refac_sim_code_par_v0,sim_code_detection, [["c:/cygwin/home/hl/demo/c.erl"], 5, 40, 2, 4, 0.8, [], 8]}, [refac_sim_code_par_v0],[])
%% percept_profile:start({file, "foo3.dat"}, {foo,a1, [1]}, [foo], []).


%% percept2_db:gen_callgraph_img(list_to_pid("<0.1132.0>")).

%% percept2:profile({file, "mergesort.dat"}, {mergesort, msort_lte,[lists:reverse(lists:seq(1,2000))]}, [message, process_scheduling, concurrency,garbagage_collection,{function, [{mergesort, '_','_'}]}]).

%% percept2:analyze("mergesort.dat").

%% percept2:profile({file, "sim_code_v3.dat"}, {refac_sim_code_par_v3,sim_code_detection, [["c:/cygwin/home/hl/test"], 5, 40, 2, 4, 0.8, [], 8]},  [message, process_scheduling, concurrency,{function, [{refac_sim_code_par_v0, '_','_'}]}]).

%% To profile percept itself.
%% percept2:profile({file, "percept.dat"}, {percept2,analyze, ["sim_code_v2.dat"]},  [message, process_scheduling, concurrency,{function, [{percept2_db, '_','_'}, {percept2, '_','_'}]}]).

 %%percept2:analyze("percept.dat").


%%percept2:analyze("dialyzer.dat").
%% percept2:profile({file, "percept_process_img.dat"}, {percept2_db,gen_process_tree_img, []},  [message, process_scheduling, concurrency,{function, [{percept2_db, '_','_'}, {percept2, '_','_'}]}]).
%%percept2:analyze("percept_process_img.dat").


 %% percept2:analyze(["sim_code_v30.dat", "sim_code_v31.dat"]).
%%percept2_db:select({activity, []}).


%% percept2:profile({file, "sim_code_v5"}, {refac_sim_code_par_v3,sim_code_detection, [["c:/cygwin/home/hl/test"], 5, 40, 2, 4, 0.8, [], 8]},  [message, process_scheduling, concurrency,{function, [{refac_sim_code_par_v3, '_','_'}]}]).

%% percept2:profile({file, "sim_code_v6"}, {refac_sim_code_par_v3,sim_code_detection, [["c:/cygwin/home/hl/test"], 5, 40, 2, 4, 0.8, [], 8]},  [message, process_scheduling, concurrency,{function, [{refac_sim_code_par_v3, '_','_'}]}]).

%%percept2:analyze(["sim_code_v50.dat", "sim_code_v51.dat", "sim_code_v52.dat"]).

 %% percept2:analyze(["sim_code_v60.dat", "sim_code_v61.dat", "sim_code_v62.dat","sim_code_v63.dat", "sim_code_v64.dat","sim_code_v6.dat", "sim_code_v66.dat", "sim_code_v67.dat","sim_code_v68.dat","sim_code_v69.dat", "sim_code_v610.dat","sim_code_v611.dat","sim_code_v612.dat"]).

 %% percept2:analyze(["sim_code_v60.dat", "sim_code_v61.dat", "sim_code_v62.dat","sim_code_v63.dat", "sim_code_v64.dat","sim_code_v65.dat", "sim_code_v66.dat"]).

%% percept2_graph:scheduler_graph(0, "range_min=0.0000&range_max=2.9328&width=532&height=600").