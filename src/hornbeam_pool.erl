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

%%% @doc Static Python context pool using ETS for O(1) lookup.
%%%
%%% This module provides scheduler-affinity based context assignment for
%%% optimal cache locality and reduced contention. Each scheduler gets
%%% a pre-assigned context via phash2(scheduler_id).
%%%
%%% Key features:
%%% - O(1) context lookup via ETS lookup_element
%%% - Scheduler affinity for cache locality
%%% - No gen_server overhead for hot path
%%% - Atomic call counters via ETS update_counter
%%% - Automatic restart on context crash
-module(hornbeam_pool).

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    get_context/0,
    get_context_rr/0,
    call/4,
    call/5,
    pool_size/0,
    stats/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(TABLE, hornbeam_pool).
-define(DEFAULT_POOL_SIZE, erlang:system_info(schedulers)).

-record(state, {
    pool_size :: non_neg_integer(),
    monitors :: #{pid() => {pos_integer(), reference()}}  % pid -> {idx, mref}
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the context pool with default size (one per scheduler).
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

%% @doc Start the context pool with options.
%%
%% Options:
%% - pool_size: Number of contexts (default: number of schedulers)
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

%% @doc Get a context from the pool using scheduler affinity.
%%
%% Returns the context assigned to the current scheduler for optimal
%% cache locality and reduced contention. O(1) lookup via ETS.
-spec get_context() -> pid().
get_context() ->
    SchedId = erlang:system_info(scheduler_id),
    N = ets:lookup_element(?TABLE, pool_size, 2),
    Idx = (SchedId - 1) rem N,
    ets:lookup_element(?TABLE, {context, Idx}, 2).

%% @doc Get a context from the pool using round-robin selection.
%%
%% Uses an atomic counter for fair distribution across all contexts.
%% Useful when scheduler affinity isn't desired (e.g., long-running requests).
-spec get_context_rr() -> pid().
get_context_rr() ->
    N = ets:lookup_element(?TABLE, pool_size, 2),
    Idx = ets:update_counter(?TABLE, rr_counter, {2, 1, N - 1, 0}),
    ets:lookup_element(?TABLE, {context, Idx}, 2).

%% @doc Call a Python function using a pooled context.
%%
%% Automatically selects a context using scheduler affinity.
%% Falls back to py:call if pool is not enabled.
-spec call(atom() | binary(), atom() | binary(), list(), map()) ->
    {ok, term()} | {error, term()}.
call(Module, Func, Args, Kwargs) ->
    call(Module, Func, Args, Kwargs, 30000).

%% @doc Call a Python function with timeout.
-spec call(atom() | binary(), atom() | binary(), list(), map(), timeout()) ->
    {ok, term()} | {error, term()}.
call(Module, Func, Args, Kwargs, Timeout) ->
    SchedId = erlang:system_info(scheduler_id),
    N = ets:lookup_element(?TABLE, pool_size, 2),
    Idx = (SchedId - 1) rem N,
    Ctx = ets:lookup_element(?TABLE, {context, Idx}, 2),
    ets:update_counter(?TABLE, {counter, Idx}, 1),
    py_context:call(Ctx, Module, Func, Args, Kwargs, Timeout).

%% @doc Get the pool size.
-spec pool_size() -> pos_integer().
pool_size() ->
    ets:lookup_element(?TABLE, pool_size, 2).

%% @doc Get pool statistics.
-spec stats() -> map().
stats() ->
    PoolSize = ets:lookup_element(?TABLE, pool_size, 2),
    CallCounts = [ets:lookup_element(?TABLE, {counter, Idx}, 2)
                  || Idx <- lists:seq(0, PoolSize - 1)],
    #{
        pool_size => PoolSize,
        call_counts => CallCounts,
        total_calls => lists:sum(CallCounts)
    }.

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    %% Create ETS table for pool data
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),

    %% Pool size: Opts > app env > default (schedulers)
    PoolSize = case maps:get(pool_size, Opts, undefined) of
        undefined ->
            application:get_env(hornbeam, pool_size, ?DEFAULT_POOL_SIZE);
        Size ->
            Size
    end,

    %% Try to create contexts (may fail if Python not started)
    {Monitors, ActualSize} = try
        create_contexts(PoolSize)
    catch
        _:_ ->
            %% Python not ready - start with empty pool
            error_logger:info_msg("hornbeam_pool: Python not ready, starting without contexts~n"),
            {#{}, 0}
    end,

    %% Initialize counters to 0
    lists:foreach(fun(Idx) ->
        ets:insert(?TABLE, {{counter, Idx}, 0})
    end, lists:seq(0, max(0, ActualSize - 1))),

    %% Initialize round-robin counter
    ets:insert(?TABLE, {rr_counter, 0}),

    %% Store pool size
    ets:insert(?TABLE, {pool_size, ActualSize}),

    {ok, #state{
        pool_size = ActualSize,
        monitors = Monitors
    }}.

handle_call(get_pool_size, _From, #state{pool_size = PoolSize} = State) ->
    {reply, PoolSize, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, Pid, Reason}, #state{monitors = Monitors} = State) ->
    %% A context died - find and restart it
    case maps:get(Pid, Monitors, undefined) of
        {Idx, MRef} ->
            error_logger:warning_msg("hornbeam_pool: Context ~p died: ~p, restarting~n",
                                     [Idx, Reason]),
            {NewCtx, NewMRef} = start_context(Idx),
            ets:insert(?TABLE, {{context, Idx}, NewCtx}),
            NewMonitors = maps:remove(Pid, Monitors),
            NewMonitors2 = maps:put(NewCtx, {Idx, NewMRef}, NewMonitors),
            {noreply, State#state{monitors = NewMonitors2}};
        undefined ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{pool_size = PoolSize}) ->
    %% Stop all contexts
    lists:foreach(fun(Idx) ->
        case ets:lookup(?TABLE, {context, Idx}) of
            [] -> ok;
            [{_, Ctx}] ->
                catch py_context:stop(Ctx)
        end
    end, lists:seq(0, PoolSize - 1)),
    %% Delete ETS table
    catch ets:delete(?TABLE),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

create_contexts(PoolSize) ->
    Monitors = lists:foldl(fun(Idx, Acc) ->
        {Ctx, MRef} = start_context(Idx),
        ets:insert(?TABLE, {{context, Idx}, Ctx}),
        maps:put(Ctx, {Idx, MRef}, Acc)
    end, #{}, lists:seq(0, PoolSize - 1)),
    {Monitors, PoolSize}.

start_context(Id) ->
    %% Use 'auto' mode - detects subinterp on Python 3.12+, worker otherwise
    {ok, Ctx} = py_context:start_link(Id, auto),
    MRef = erlang:monitor(process, Ctx),
    {Ctx, MRef}.
