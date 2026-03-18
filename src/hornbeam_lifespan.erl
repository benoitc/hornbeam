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

%%% @doc ASGI Lifespan protocol manager.
%%%
%%% This module implements the ASGI lifespan protocol for application
%%% startup and shutdown events. It allows ASGI applications to perform
%%% initialization (loading ML models, connecting to databases) at startup
%%% and cleanup at shutdown.
%%%
%%% == Lifespan Protocol ==
%%%
%%% The lifespan protocol consists of these events:
%%%
%%% Startup:
%%% &lt;ol&gt;
%%% &lt;li&gt;Server sends: type = "lifespan.startup"&lt;/li&gt;
%%% &lt;li&gt;App responds: type = "lifespan.startup.complete" or
%%%     type = "lifespan.startup.failed"&lt;/li&gt;
%%% &lt;/ol&gt;
%%%
%%% Shutdown:
%%% &lt;ol&gt;
%%% &lt;li&gt;Server sends: type = "lifespan.shutdown"&lt;/li&gt;
%%% &lt;li&gt;App responds: type = "lifespan.shutdown.complete"&lt;/li&gt;
%%% &lt;/ol&gt;
%%%
%%% == Configuration ==
%%%
%%% The lifespan setting can be:
%%% &lt;ul&gt;
%%% &lt;li&gt;auto: Detect if app supports lifespan (default)&lt;/li&gt;
%%% &lt;li&gt;on: Require lifespan support, fail if not supported&lt;/li&gt;
%%% &lt;li&gt;off: Disable lifespan protocol&lt;/li&gt;
%%% &lt;/ul&gt;
-module(hornbeam_lifespan).

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    startup/0,
    startup/1,
    startup/2,
    shutdown/0,
    shutdown/1,
    get_state/0,
    get_state/1,
    set_state/2,
    get_context/0,
    is_running/0,
    is_running/1
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
-define(DEFAULT_TIMEOUT, 30000).
-define(CACHE_TABLE, hornbeam_lifespan_cache).

%% Per-mount lifespan tracking
-record(mount_lifespan, {
    mount_id :: binary(),
    app_module :: binary(),
    app_callable :: binary(),
    started = false :: boolean(),
    supported = unknown :: boolean() | unknown
}).

-record(state, {
    app_module :: binary() | undefined,
    app_callable :: binary() | undefined,
    lifespan_mode :: auto | on | off,
    lifespan_state :: map(),
    py_context :: term() | undefined,  %% Python context for affinity
    started = false :: boolean(),
    supported = unknown :: boolean() | unknown,
    %% Per-mount tracking for multi-app mode
    mounts = #{} :: #{binary() => #mount_lifespan{}}
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the lifespan manager.
start_link() ->
    start_link(#{}).

%% @doc Start the lifespan manager with options.
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

%% @doc Run lifespan startup protocol.
%%
%% This should be called after the application is loaded but before
%% accepting requests.
-spec startup() -> ok | {error, term()}.
startup() ->
    startup(#{}).

%% @doc Run lifespan startup with options.
-spec startup(map()) -> ok | {error, term()}.
startup(Opts) ->
    gen_server:call(?SERVER, {startup, Opts}, infinity).

%% @doc Run lifespan startup for a specific mount.
%% Used in multi-app mode to run lifespan per mounted app.
-spec startup(binary(), map()) -> ok | {error, term()}.
startup(MountId, Opts) when is_binary(MountId) ->
    gen_server:call(?SERVER, {startup_mount, MountId, Opts}, infinity).

%% @doc Run lifespan shutdown protocol.
-spec shutdown() -> ok | {error, term()}.
shutdown() ->
    gen_server:call(?SERVER, shutdown, infinity).

%% @doc Run lifespan shutdown for a specific mount.
-spec shutdown(binary()) -> ok | {error, term()}.
shutdown(MountId) when is_binary(MountId) ->
    gen_server:call(?SERVER, {shutdown_mount, MountId}, infinity).

%% @doc Get the lifespan state for single-app mode (backward compat).
%% Uses ETS cache for fast concurrent reads.
-spec get_state() -> map().
get_state() ->
    case ets:lookup(?CACHE_TABLE, lifespan_state) of
        [{lifespan_state, State}] -> State;
        [] -> #{}
    end.

%% @doc Get the lifespan state for a specific mount.
%% Used in multi-app mode to get per-mount state.
-spec get_state(binary()) -> map().
get_state(MountId) when is_binary(MountId) ->
    case ets:lookup(?CACHE_TABLE, {lifespan_state, MountId}) of
        [{{lifespan_state, MountId}, State}] -> State;
        [] -> #{}
    end.

%% @doc Set the lifespan state for a specific mount.
%% Used after startup to store per-mount state in ETS.
-spec set_state(binary(), map()) -> ok.
set_state(MountId, State) when is_binary(MountId), is_map(State) ->
    ets:insert(?CACHE_TABLE, {{lifespan_state, MountId}, State}),
    ok.

%% @doc Check if lifespan is running (single-app mode).
-spec is_running() -> boolean().
is_running() ->
    case ets:lookup(?CACHE_TABLE, started) of
        [{started, Started}] -> Started;
        [] -> false
    end.

%% @doc Check if lifespan is running for a specific mount.
-spec is_running(binary()) -> boolean().
is_running(MountId) when is_binary(MountId) ->
    case ets:lookup(?CACHE_TABLE, {started, MountId}) of
        [{{started, MountId}, Started}] -> Started;
        [] -> false
    end.

%% @doc Get the Python context for ASGI calls.
%%
%% This context provides affinity - all calls using this context
%% share the same Python worker and module state.
%% Uses ETS cache for fast concurrent reads (avoids gen_server bottleneck).
-spec get_context() -> term() | undefined.
get_context() ->
    case ets:lookup(?CACHE_TABLE, py_context) of
        [{py_context, Ctx}] -> Ctx;
        [] -> undefined
    end.

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init(Opts) ->
    LifespanMode = maps:get(lifespan, Opts, auto),

    %% Create ETS table for fast concurrent reads (avoids gen_server bottleneck)
    ?CACHE_TABLE = ets:new(?CACHE_TABLE, [
        named_table,
        public,
        {read_concurrency, true}
    ]),

    %% Get a Python context from hornbeam_context_pool for ASGI affinity
    %% This ensures module-level state persists across requests
    %% Using hornbeam_context_pool ensures priv/ is in sys.path
    PyContext = try
        hornbeam_context_pool:get_context_ref()
    catch
        _:_ -> undefined
    end,

    %% Cache initial values
    ets:insert(?CACHE_TABLE, [
        {py_context, PyContext},
        {lifespan_state, #{}},
        {started, false}
    ]),

    {ok, #state{
        lifespan_mode = LifespanMode,
        lifespan_state = #{},
        py_context = PyContext
    }}.

handle_call({startup, Opts}, _From, #state{py_context = PyContext} = State) ->
    AppModule = hornbeam_config:get_config(app_module),
    AppCallable = hornbeam_config:get_config(app_callable),
    LifespanMode = maps:get(lifespan, Opts, State#state.lifespan_mode),

    case LifespanMode of
        off ->
            %% Update ETS cache
            ets:insert(?CACHE_TABLE, {started, true}),
            {reply, ok, State#state{started = true, supported = false}};
        _ ->
            %% Try to run lifespan startup with context
            case run_startup(AppModule, AppCallable, PyContext) of
                {ok, LifespanState} ->
                    %% Update ETS cache
                    ets:insert(?CACHE_TABLE, [
                        {lifespan_state, LifespanState},
                        {started, true}
                    ]),
                    {reply, ok, State#state{
                        app_module = AppModule,
                        app_callable = AppCallable,
                        lifespan_mode = LifespanMode,
                        lifespan_state = LifespanState,
                        started = true,
                        supported = true
                    }};
                {error, not_supported} when LifespanMode =:= auto ->
                    %% Lifespan not supported, but that's OK in auto mode
                    %% Update ETS cache
                    ets:insert(?CACHE_TABLE, {started, true}),
                    {reply, ok, State#state{
                        app_module = AppModule,
                        app_callable = AppCallable,
                        lifespan_mode = LifespanMode,
                        started = true,
                        supported = false
                    }};
                {error, not_supported} when LifespanMode =:= on ->
                    %% Lifespan required but not supported
                    {reply, {error, lifespan_not_supported}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

%% Per-mount startup handler
handle_call({startup_mount, MountId, Opts}, _From, #state{py_context = PyContext, mounts = Mounts} = State) ->
    AppModule = maps:get(app_module, Opts),
    AppCallable = maps:get(app_callable, Opts),
    LifespanMode = maps:get(lifespan, Opts, auto),

    case LifespanMode of
        off ->
            %% Update ETS cache for this mount
            ets:insert(?CACHE_TABLE, {{started, MountId}, true}),
            MountLifespan = #mount_lifespan{
                mount_id = MountId,
                app_module = AppModule,
                app_callable = AppCallable,
                started = true,
                supported = false
            },
            {reply, ok, State#state{mounts = Mounts#{MountId => MountLifespan}}};
        _ ->
            %% Try to run lifespan startup with mount_id
            case run_startup_mount(MountId, AppModule, AppCallable, PyContext) of
                {ok, LifespanState} ->
                    %% Update ETS cache for this mount
                    ets:insert(?CACHE_TABLE, [
                        {{lifespan_state, MountId}, LifespanState},
                        {{started, MountId}, true}
                    ]),
                    MountLifespan = #mount_lifespan{
                        mount_id = MountId,
                        app_module = AppModule,
                        app_callable = AppCallable,
                        started = true,
                        supported = true
                    },
                    {reply, ok, State#state{mounts = Mounts#{MountId => MountLifespan}}};
                {error, not_supported} when LifespanMode =:= auto ->
                    %% Lifespan not supported, but that's OK in auto mode
                    ets:insert(?CACHE_TABLE, {{started, MountId}, true}),
                    MountLifespan = #mount_lifespan{
                        mount_id = MountId,
                        app_module = AppModule,
                        app_callable = AppCallable,
                        started = true,
                        supported = false
                    },
                    {reply, ok, State#state{mounts = Mounts#{MountId => MountLifespan}}};
                {error, not_supported} when LifespanMode =:= on ->
                    {reply, {error, lifespan_not_supported}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

%% Per-mount shutdown handler
handle_call({shutdown_mount, MountId}, _From, #state{py_context = PyContext, mounts = Mounts} = State) ->
    case maps:get(MountId, Mounts, undefined) of
        undefined ->
            {reply, ok, State};
        #mount_lifespan{started = false} ->
            {reply, ok, State};
        #mount_lifespan{supported = false} = ML ->
            ets:insert(?CACHE_TABLE, [
                {{started, MountId}, false},
                {{lifespan_state, MountId}, #{}}
            ]),
            {reply, ok, State#state{mounts = Mounts#{MountId => ML#mount_lifespan{started = false}}}};
        #mount_lifespan{app_module = AppModule, app_callable = AppCallable} = ML ->
            Result = run_shutdown_mount(MountId, AppModule, AppCallable, PyContext),
            ets:insert(?CACHE_TABLE, [
                {{started, MountId}, false},
                {{lifespan_state, MountId}, #{}}
            ]),
            {reply, Result, State#state{mounts = Mounts#{MountId => ML#mount_lifespan{started = false}}}}
    end;

handle_call(shutdown, _From, #state{started = false} = State) ->
    {reply, ok, State};

handle_call(shutdown, _From, #state{supported = false} = State) ->
    %% Update ETS cache
    ets:insert(?CACHE_TABLE, [{started, false}, {lifespan_state, #{}}]),
    {reply, ok, State#state{started = false}};

handle_call(shutdown, _From, #state{app_module = AppModule,
                                     app_callable = AppCallable,
                                     py_context = PyContext} = State) ->
    Result = run_shutdown(AppModule, AppCallable, PyContext),
    %% Update ETS cache
    ets:insert(?CACHE_TABLE, [{started, false}, {lifespan_state, #{}}]),
    {reply, Result, State#state{started = false, lifespan_state = #{}}};

handle_call(get_state, _From, #state{lifespan_state = LifespanState} = State) ->
    {reply, LifespanState, State};

handle_call(is_running, _From, #state{started = Started} = State) ->
    {reply, Started, State};

handle_call(get_context, _From, #state{py_context = PyContext} = State) ->
    {reply, PyContext, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{started = true, supported = true,
                          app_module = AppModule,
                          app_callable = AppCallable,
                          py_context = PyContext}) ->
    %% Run shutdown on terminate
    _ = run_shutdown(AppModule, AppCallable, PyContext),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

run_startup(AppModule, AppCallable, PyContext) ->
    %% Use lifespan_timeout for startup/shutdown, falls back to general timeout
    TimeoutMs = case hornbeam_config:get_config(lifespan_timeout) of
        undefined ->
            case hornbeam_config:get_config(timeout) of
                undefined -> ?DEFAULT_TIMEOUT;
                T -> T
            end;
        LT -> LT
    end,

    try
        %% Use context-aware call for affinity
        %% Pass timeout to Python so it can use the same value
        Result = case PyContext of
            undefined ->
                py:call(hornbeam_lifespan_runner, startup,
                       [AppModule, AppCallable, TimeoutMs], #{});
            CtxRef ->
                py_nif:context_call(CtxRef, <<"hornbeam_lifespan_runner">>, <<"startup">>,
                                   [AppModule, AppCallable, TimeoutMs], #{})
        end,
        case Result of
            {ok, Response} ->
                handle_startup_response(Response);
            {error, StartupError} ->
                {error, StartupError}
        end
    catch
        Class:CatchReason ->
            error_logger:error_msg("Lifespan startup error: ~p:~p~n",
                                   [Class, CatchReason]),
            {error, {Class, CatchReason}}
    end.

handle_startup_response(Response) ->
    case maps:get(<<"type">>, Response, undefined) of
        <<"lifespan.startup.complete">> ->
            State = maps:get(<<"state">>, Response, #{}),
            {ok, State};
        <<"lifespan.startup.failed">> ->
            Message = maps:get(<<"message">>, Response, <<"Unknown error">>),
            {error, {startup_failed, Message}};
        <<"lifespan.not_supported">> ->
            {error, not_supported};
        _ ->
            {error, {invalid_response, Response}}
    end.

run_shutdown(AppModule, AppCallable, PyContext) ->
    try
        %% Use context-aware call for affinity
        Result = case PyContext of
            undefined ->
                py:call(hornbeam_lifespan_runner, shutdown,
                       [AppModule, AppCallable], #{});
            CtxRef ->
                py_nif:context_call(CtxRef, <<"hornbeam_lifespan_runner">>, <<"shutdown">>,
                                   [AppModule, AppCallable], #{})
        end,
        case Result of
            {ok, Response} ->
                handle_shutdown_response(Response);
            {error, ShutdownError} ->
                {error, ShutdownError}
        end
    catch
        Class:CatchReason ->
            error_logger:error_msg("Lifespan shutdown error: ~p:~p~n",
                                   [Class, CatchReason]),
            {error, {Class, CatchReason}}
    end.

%% @private
%% Run lifespan startup for a specific mount (multi-app mode)
run_startup_mount(MountId, AppModule, AppCallable, PyContext) ->
    TimeoutMs = case hornbeam_config:get_config(lifespan_timeout) of
        undefined ->
            case hornbeam_config:get_config(timeout) of
                undefined -> ?DEFAULT_TIMEOUT;
                T -> T
            end;
        LT -> LT
    end,

    try
        %% Pass mount_id to Python so it can store state per mount
        Result = case PyContext of
            undefined ->
                py:call(hornbeam_lifespan_runner, startup_mount,
                       [MountId, AppModule, AppCallable, TimeoutMs], #{});
            CtxRef ->
                py_nif:context_call(CtxRef, <<"hornbeam_lifespan_runner">>, <<"startup_mount">>,
                                   [MountId, AppModule, AppCallable, TimeoutMs], #{})
        end,
        case Result of
            {ok, Response} ->
                handle_startup_response(Response);
            {error, StartupError} ->
                {error, StartupError}
        end
    catch
        Class:CatchReason ->
            error_logger:error_msg("Lifespan mount startup error (~s): ~p:~p~n",
                                   [MountId, Class, CatchReason]),
            {error, {Class, CatchReason}}
    end.

%% @private
%% Run lifespan shutdown for a specific mount (multi-app mode)
run_shutdown_mount(MountId, AppModule, AppCallable, PyContext) ->
    try
        %% Pass mount_id to Python for per-mount cleanup
        Result = case PyContext of
            undefined ->
                py:call(hornbeam_lifespan_runner, shutdown_mount,
                       [MountId, AppModule, AppCallable], #{});
            CtxRef ->
                py_nif:context_call(CtxRef, <<"hornbeam_lifespan_runner">>, <<"shutdown_mount">>,
                                   [MountId, AppModule, AppCallable], #{})
        end,
        case Result of
            {ok, Response} ->
                handle_shutdown_response(Response);
            {error, ShutdownError} ->
                {error, ShutdownError}
        end
    catch
        Class:CatchReason ->
            error_logger:error_msg("Lifespan mount shutdown error (~s): ~p:~p~n",
                                   [MountId, Class, CatchReason]),
            {error, {Class, CatchReason}}
    end.

handle_shutdown_response(Response) ->
    case maps:get(<<"type">>, Response, undefined) of
        <<"lifespan.shutdown.complete">> ->
            ok;
        _ ->
            %% Accept any response during shutdown
            ok
    end.
