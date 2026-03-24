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

%%% @doc Context pool using py_context_router with cached NIF refs.
%%%
%%% Uses py_context_router for context lifecycle management and caches
%%% NIF references in persistent_term for O(1) lookup without message passing.
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
    add_paths/1,
    preload_app/3
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    pool_size :: pos_integer(),
    context_mode :: worker | owngil,
    contexts :: [pid()],          %% Context pids from py_context_router
    nif_refs :: #{pos_integer() => reference()}  %% Cached NIF refs
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
%% - context_mode: worker | owngil (default: worker)
%%   - worker: Standard sub-interpreter mode
%%   - owngil: Per-interpreter GIL mode (Python 3.12+, true parallelism)
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

%% @doc Preload WSGI/ASGI application in all contexts.
%%
%% Imports the app module and caches the callable for fast access.
-spec preload_app(wsgi | asgi, binary(), binary()) -> ok.
preload_app(WorkerClass, AppModule, AppCallable) ->
    gen_server:call(?MODULE, {preload_app, WorkerClass, AppModule, AppCallable}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    PoolSize = maps:get(pool_size, Opts,
        application:get_env(hornbeam, context_pool_size, ?DEFAULT_POOL_SIZE)),
    ContextMode = maps:get(context_mode, Opts,
        application:get_env(hornbeam, context_mode, worker)),

    %% Create atomic counter for round-robin
    Counter = atomics:new(1, [{signed, false}]),
    persistent_term:put(hornbeam_context_counter, Counter),

    %% Start py_context_router if not already started
    case py_context_router:is_started() of
        true -> ok;
        false ->
            {ok, _} = py_context_router:start(#{contexts => PoolSize, mode => ContextMode})
    end,

    %% Get contexts from py_context_router and cache NIF refs
    Contexts = py_context_router:contexts(),
    NifRefs = cache_nif_refs(Contexts),

    %% Setup hornbeam-specific modules in each context
    setup_contexts(NifRefs),

    persistent_term:put(hornbeam_context_pool_size, PoolSize),

    {ok, #state{pool_size = PoolSize, context_mode = ContextMode,
                contexts = Contexts, nif_refs = NifRefs}}.

handle_call(stats, _From, #state{pool_size = PoolSize, context_mode = ContextMode} = State) ->
    Stats = #{
        pool_size => PoolSize,
        context_mode => ContextMode,
        execution_mode => py_nif:execution_mode()
    },
    {reply, Stats, State};

handle_call({add_paths, Paths}, _From, #state{nif_refs = NifRefs} = State) ->
    %% Add paths to all contexts
    maps:foreach(fun(_Id, Ref) ->
        add_paths_to_context(Ref, Paths)
    end, NifRefs),
    {reply, ok, State};

handle_call({preload_app, WorkerClass, AppModule, AppCallable}, _From,
            #state{nif_refs = NifRefs} = State) ->
    %% Preload app in all contexts
    WorkerModule = case WorkerClass of
        wsgi -> <<"hornbeam_wsgi_worker">>;
        asgi -> <<"hornbeam_asgi_worker">>
    end,
    maps:foreach(fun(_Id, Ref) ->
        case py_nif:context_call(Ref, WorkerModule, <<"preload_app">>,
                                 [AppModule, AppCallable], #{}) of
            {ok, <<"ok">>} -> ok;
            {error, Err} ->
                error_logger:warning_msg(
                    "hornbeam: failed to preload app in context: ~p~n", [Err])
        end
    end, NifRefs),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{pool_size = PoolSize}) ->
    %% py_context_router manages context lifecycle, just clean up our cached refs
    lists:foreach(fun(Id) ->
        catch persistent_term:erase({hornbeam_context, Id})
    end, lists:seq(0, PoolSize - 1)),
    catch persistent_term:erase(hornbeam_context_pool_size),
    catch persistent_term:erase(hornbeam_context_counter),
    ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

%% @private
%% Cache NIF refs from py_context_router contexts in persistent_term
cache_nif_refs(Contexts) ->
    {NifRefs, _} = lists:foldl(fun(Ctx, {Acc, Id}) ->
        Ref = py_context:get_nif_ref(Ctx),
        InterpId = case py_context:get_interp_id(Ctx) of
            {ok, IId} -> IId;
            _ -> Id
        end,
        persistent_term:put({hornbeam_context, Id}, {Ref, InterpId}),
        {maps:put(Id, Ref, Acc), Id + 1}
    end, {#{}, 0}, Contexts),
    NifRefs.

%% @private
%% Setup hornbeam-specific modules in each context
setup_contexts(NifRefs) ->
    PrivDir = code:priv_dir(hornbeam),
    PrivDirBin = list_to_binary(PrivDir),
    SetupCode = <<"
import sys
priv_dir = '", PrivDirBin/binary, "'
if priv_dir not in sys.path:
    sys.path.insert(0, priv_dir)
import hornbeam_wsgi_worker
import hornbeam_asgi_worker
">>,
    maps:foreach(fun(Id, Ref) ->
        case py_nif:context_exec(Ref, SetupCode) of
            ok -> ok;
            {error, SetupError} ->
                error_logger:warning_msg(
                    "hornbeam_context_pool: context ~p setup warning: ~p~n",
                    [Id, SetupError])
        end
    end, NifRefs).

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
