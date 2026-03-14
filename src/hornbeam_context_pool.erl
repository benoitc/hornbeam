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

%%% @doc Context pool using persistent_term for zero-copy access.
%%%
%%% Stores Python context references in persistent_term for O(1) lookup
%%% with no message passing or copying overhead.
%%%
%%% Each context is a sub-interpreter (Python 3.12+) or worker thread.
%%% With free-threading Python (3.13+), contexts execute truly in parallel.
%%%
%%% @end
-module(hornbeam_context_pool).

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    get_context/0,
    get_context_ref/0,
    get_context_rr/0,
    pool_size/0,
    stats/0,
    add_paths/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    pool_size :: pos_integer(),
    contexts :: #{pos_integer() => reference()}
}).

-define(DEFAULT_POOL_SIZE, erlang:system_info(schedulers)).

%% ============================================================================
%% API
%% ============================================================================

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
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc Get a context using scheduler affinity.
%%
%% Returns {Ref, InterpId} for the context assigned to the current scheduler.
%% Zero-copy via persistent_term.
-spec get_context() -> {reference(), non_neg_integer()}.
get_context() ->
    N = persistent_term:get(hornbeam_context_pool_size),
    Id = erlang:system_info(scheduler_id) rem N,
    persistent_term:get({hornbeam_context, Id}).

%% @doc Get only the context reference (most common use case).
-spec get_context_ref() -> reference().
get_context_ref() ->
    {Ref, _InterpId} = get_context(),
    Ref.

%% @doc Get a context using round-robin selection.
%%
%% Uses an atomic counter for fair distribution across all contexts.
-spec get_context_rr() -> {reference(), non_neg_integer()}.
get_context_rr() ->
    N = persistent_term:get(hornbeam_context_pool_size),
    Counter = atomics:add_get(persistent_term:get(hornbeam_context_counter), 1, 1),
    Id = (Counter - 1) rem N,
    persistent_term:get({hornbeam_context, Id}).

%% @doc Get the pool size.
-spec pool_size() -> pos_integer().
pool_size() ->
    persistent_term:get(hornbeam_context_pool_size).

%% @doc Get pool statistics.
-spec stats() -> map().
stats() ->
    gen_server:call(?MODULE, stats).

%% @doc Add paths to sys.path in all contexts.
%%
%% Call this after starting the context pool to add user-specified paths
%% (like pythonpath from config) to all Python contexts.
-spec add_paths([string() | binary()]) -> ok.
add_paths(Paths) when is_list(Paths) ->
    gen_server:call(?MODULE, {add_paths, Paths}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    PoolSize = maps:get(pool_size, Opts,
        application:get_env(hornbeam, context_pool_size, ?DEFAULT_POOL_SIZE)),

    %% Create atomic counter for round-robin
    Counter = atomics:new(1, [{signed, false}]),
    persistent_term:put(hornbeam_context_counter, Counter),

    %% Create contexts and store in persistent_term
    Contexts = create_contexts(PoolSize),

    persistent_term:put(hornbeam_context_pool_size, PoolSize),

    {ok, #state{pool_size = PoolSize, contexts = Contexts}}.

handle_call(stats, _From, #state{pool_size = PoolSize} = State) ->
    Stats = #{
        pool_size => PoolSize,
        execution_mode => py_nif:execution_mode()
    },
    {reply, Stats, State};

handle_call({add_paths, Paths}, _From, #state{contexts = Contexts} = State) ->
    %% Add paths to all contexts
    maps:foreach(fun(_Id, Ref) ->
        add_paths_to_context(Ref, Paths)
    end, Contexts),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{pool_size = PoolSize, contexts = Contexts}) ->
    %% Destroy contexts
    maps:foreach(fun(_Id, Ref) ->
        catch py_nif:context_destroy(Ref)
    end, Contexts),

    %% Clean up persistent_term entries
    lists:foreach(fun(Id) ->
        catch persistent_term:erase({hornbeam_context, Id})
    end, lists:seq(0, PoolSize - 1)),
    catch persistent_term:erase(hornbeam_context_pool_size),
    catch persistent_term:erase(hornbeam_context_counter),
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

create_contexts(PoolSize) ->
    PrivDir = code:priv_dir(hornbeam),
    PrivDirBin = list_to_binary(PrivDir),

    lists:foldl(fun(Id, Acc) ->
        {Ref, InterpId} = create_context(Id, PrivDirBin),
        persistent_term:put({hornbeam_context, Id}, {Ref, InterpId}),
        maps:put(Id, Ref, Acc)
    end, #{}, lists:seq(0, PoolSize - 1)).

%% @private
%% Add paths to a context's sys.path
add_paths_to_context(Ref, Paths) ->
    lists:foreach(fun(Path) ->
        PathBin = if
            is_binary(Path) -> Path;
            is_list(Path) -> list_to_binary(Path);
            true -> Path
        end,
        AbsPath = list_to_binary(filename:absname(binary_to_list(PathBin))),
        Code = <<"import sys; sys.path.insert(0, '", AbsPath/binary, "') if '", AbsPath/binary, "' not in sys.path else None">>,
        case py_nif:context_exec(Ref, Code) of
            ok -> ok;
            {error, Err} ->
                error_logger:warning_msg("Failed to add path ~s to context: ~p~n", [AbsPath, Err])
        end
    end, Paths).

create_context(Id, PrivDir) ->
    case py_nif:context_create(auto) of
        {ok, Ref, InterpId} ->
            %% Set up callback handler (for erlang.call from Python)
            py_nif:context_set_callback_handler(Ref, self()),

            %% Extend erlang module first (must happen before importing workers)
            %% This makes erlang.send, erlang.call, erlang.schedule_inline available
            py_context:extend_erlang_module_in_context(Ref),

            %% Add priv dir to sys.path and preload worker modules
            SetupCode = <<"
import sys
priv_dir = '", PrivDir/binary, "'
if priv_dir not in sys.path:
    sys.path.insert(0, priv_dir)
import hornbeam_wsgi_worker
import hornbeam_asgi_worker
">>,
            case py_nif:context_exec(Ref, SetupCode) of
                ok -> ok;
                {error, SetupError} ->
                    error_logger:warning_msg(
                        "hornbeam_context_pool: context ~p setup warning: ~p~n",
                        [Id, SetupError])
            end,

            {Ref, InterpId};
        {error, Reason} ->
            error({context_create_failed, Id, Reason})
    end.
