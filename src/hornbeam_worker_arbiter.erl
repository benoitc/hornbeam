%% Copyright 2026 Benoit Chesneau
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%% @doc Per-mount gen_server managing persistent Python workers.
%%%
%%% Each arbiter manages N workers for a single mount. Workers are persistent
%%% Python processes that receive requests via channels and loop continuously,
%%% reducing Python startup overhead.
%%%
%%% Features:
%%% - O(1) channel lookup via persistent_term
%%% - Heartbeat monitoring with automatic restart
%%% - Scheduler affinity for cache locality
-module(hornbeam_worker_arbiter).

-behaviour(gen_server).

-export([
    start_link/2,
    get_channel/2,
    get_worker_count/1,
    worker_status/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(HEARTBEAT_INTERVAL, 5000).   %% Check heartbeats every 5 seconds
-define(HEARTBEAT_TIMEOUT, 15000).   %% Restart worker if no heartbeat for 15 seconds

-record(worker_info, {
    idx :: non_neg_integer(),
    channel :: term(),
    task_ref :: reference() | undefined,
    last_heartbeat :: integer(),
    status :: starting | running | stopping
}).

-record(state, {
    mount_id :: binary(),
    mount_config :: map(),
    num_workers :: pos_integer(),
    workers :: #{non_neg_integer() => #worker_info{}},
    heartbeat_timer :: reference() | undefined
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the arbiter for a mount.
%%
%% Config should contain:
%% - app_module: Python module name
%% - app_callable: Python callable name
%% - worker_class: wsgi | asgi
%% - workers: Number of workers (default: number of schedulers)
-spec start_link(MountId :: binary(), Config :: map()) ->
    {ok, pid()} | {error, term()}.
start_link(MountId, Config) ->
    gen_server:start_link(?MODULE, {MountId, Config}, []).

%% @doc Get channel for a specific worker index.
%% Uses persistent_term for O(1) lookup.
-spec get_channel(MountId :: binary(), WorkerIdx :: non_neg_integer()) -> term().
get_channel(MountId, WorkerIdx) ->
    persistent_term:get({hornbeam_worker, MountId, WorkerIdx}).

%% @doc Get number of workers for a mount.
-spec get_worker_count(MountId :: binary()) -> pos_integer().
get_worker_count(MountId) ->
    persistent_term:get({hornbeam_worker_count, MountId}).

%% @doc Get status of all workers managed by this arbiter.
-spec worker_status(pid()) -> map().
worker_status(Pid) ->
    gen_server:call(Pid, get_status).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init({MountId, Config}) ->
    process_flag(trap_exit, true),

    NumWorkers = maps:get(workers, Config, erlang:system_info(schedulers)),

    %% Store worker count for routing
    persistent_term:put({hornbeam_worker_count, MountId}, NumWorkers),

    %% Start all workers
    Workers = start_all_workers(MountId, Config, NumWorkers),

    %% Start heartbeat timer
    HeartbeatTimer = erlang:send_after(?HEARTBEAT_INTERVAL, self(), check_heartbeats),

    State = #state{
        mount_id = MountId,
        mount_config = Config,
        num_workers = NumWorkers,
        workers = Workers,
        heartbeat_timer = HeartbeatTimer
    },

    {ok, State}.

handle_call(get_status, _From, #state{workers = Workers, mount_id = MountId} = State) ->
    Now = erlang:system_time(millisecond),
    WorkerList = maps:fold(fun(Idx, #worker_info{last_heartbeat = LastHB, status = Status}, Acc) ->
        [#{
            idx => Idx,
            status => Status,
            last_heartbeat_ms_ago => Now - LastHB
        } | Acc]
    end, [], Workers),
    Reply = #{
        mount_id => MountId,
        num_workers => maps:size(Workers),
        workers => WorkerList
    },
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({heartbeat, WorkerId}, #state{workers = Workers} = State) ->
    %% Extract worker index from WorkerId (format: "mount_id_idx")
    Idx = parse_worker_idx(WorkerId),
    case maps:get(Idx, Workers, undefined) of
        undefined ->
            {noreply, State};
        WorkerInfo ->
            Now = erlang:system_time(millisecond),
            UpdatedWorker = WorkerInfo#worker_info{
                last_heartbeat = Now,
                status = running
            },
            {noreply, State#state{workers = Workers#{Idx => UpdatedWorker}}}
    end;

handle_info(check_heartbeats, #state{workers = Workers, mount_id = MountId,
                                      mount_config = Config} = State) ->
    Now = erlang:system_time(millisecond),

    %% Check each worker for heartbeat timeout
    UpdatedWorkers = maps:fold(fun(Idx, WorkerInfo, Acc) ->
        #worker_info{last_heartbeat = LastHB, status = Status} = WorkerInfo,
        case Status of
            running when (Now - LastHB) > ?HEARTBEAT_TIMEOUT ->
                %% Worker missed heartbeats - restart it
                error_logger:warning_msg("hornbeam_worker_arbiter: Worker ~s_~p missed heartbeats, restarting~n",
                                         [MountId, Idx]),
                NewWorker = restart_worker(MountId, Config, Idx, WorkerInfo),
                Acc#{Idx => NewWorker};
            _ ->
                Acc#{Idx => WorkerInfo}
        end
    end, #{}, Workers),

    %% Schedule next heartbeat check
    NewTimer = erlang:send_after(?HEARTBEAT_INTERVAL, self(), check_heartbeats),

    {noreply, State#state{workers = UpdatedWorkers, heartbeat_timer = NewTimer}};

handle_info({'EXIT', _Pid, normal}, State) ->
    %% Normal exit, likely during shutdown
    {noreply, State};

handle_info({'EXIT', _Pid, Reason}, State) ->
    %% Unexpected exit - will be handled by heartbeat timeout
    error_logger:warning_msg("hornbeam_worker_arbiter: Worker exited with reason: ~p~n", [Reason]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{workers = Workers, mount_id = MountId, num_workers = NumWorkers}) ->
    %% Send stop to all workers
    maps:foreach(fun(_Idx, #worker_info{channel = Channel}) ->
        catch py_channel:send(Channel, stop)
    end, Workers),

    %% Give workers time to stop gracefully
    timer:sleep(100),

    %% Close all channels
    maps:foreach(fun(_Idx, #worker_info{channel = Channel}) ->
        catch py_channel:close(Channel)
    end, Workers),

    %% Clean up persistent_term entries
    lists:foreach(fun(Idx) ->
        persistent_term:erase({hornbeam_worker, MountId, Idx})
    end, lists:seq(0, NumWorkers - 1)),
    persistent_term:erase({hornbeam_worker_count, MountId}),

    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

start_all_workers(MountId, Config, NumWorkers) ->
    lists:foldl(fun(Idx, Acc) ->
        WorkerInfo = start_worker(MountId, Config, Idx),
        Acc#{Idx => WorkerInfo}
    end, #{}, lists:seq(0, NumWorkers - 1)).

start_worker(MountId, Config, Idx) ->
    %% Create channel for this worker
    {ok, Channel} = py_channel:new(),

    %% Store in persistent_term for O(1) lookup
    persistent_term:put({hornbeam_worker, MountId, Idx}, Channel),

    %% Build worker ID
    WorkerId = <<MountId/binary, "_", (integer_to_binary(Idx))/binary>>,

    %% Get app config
    AppModule = maps:get(app_module, Config),
    AppCallable = maps:get(app_callable, Config),
    WorkerClass = maps:get(worker_class, Config, wsgi),

    %% Get arbiter PID for heartbeat messages
    ArbiterPid = self(),

    %% Spawn Python worker task
    TaskRef = spawn_python_worker(Channel, ArbiterPid, WorkerId,
                                   AppModule, AppCallable, WorkerClass),

    Now = erlang:system_time(millisecond),
    #worker_info{
        idx = Idx,
        channel = Channel,
        task_ref = TaskRef,
        last_heartbeat = Now,
        status = starting
    }.

restart_worker(MountId, Config, Idx, #worker_info{channel = OldChannel}) ->
    %% Close old channel (will cause Python worker to exit)
    catch py_channel:close(OldChannel),

    %% Start new worker
    start_worker(MountId, Config, Idx).

spawn_python_worker(Channel, ArbiterPid, WorkerId, AppModule, AppCallable, WorkerClass) ->
    %% Get the channel reference for Python
    ChannelRef = py_channel:get_ref(Channel),

    %% Determine which Python module/function to call
    {Module, Function} = case WorkerClass of
        wsgi -> {<<"hornbeam_wsgi_worker">>, <<"worker_loop">>};
        asgi -> {<<"hornbeam_asgi_worker">>, <<"worker_loop">>}
    end,

    %% Create a reference for tracking
    Ref = make_ref(),

    %% Schedule the Python task
    %% The worker_loop function will run until it receives 'stop'
    case py_event_loop:get_loop() of
        {ok, LoopRef} ->
            py_event_loop:run_async(LoopRef, #{
                ref => Ref,
                caller => self(),
                module => Module,
                func => Function,
                args => [ChannelRef, ArbiterPid, WorkerId, AppModule, AppCallable]
            }),
            Ref;
        {error, _} ->
            %% Fallback: use py:spawn if event loop not available
            py:spawn(Module, Function, [ChannelRef, ArbiterPid, WorkerId, AppModule, AppCallable]),
            Ref
    end.

parse_worker_idx(WorkerId) when is_binary(WorkerId) ->
    %% Parse "mount_id_idx" to get idx
    case binary:split(WorkerId, <<"_">>, [global]) of
        Parts when length(Parts) >= 2 ->
            IdxBin = lists:last(Parts),
            try binary_to_integer(IdxBin)
            catch _:_ -> 0
            end;
        _ ->
            0
    end.
