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
    shutdown/0,
    get_state/0,
    get_context/0,
    is_running/0
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

-record(state, {
    app_module :: binary() | undefined,
    app_callable :: binary() | undefined,
    lifespan_mode :: auto | on | off,
    lifespan_state :: map(),
    py_context :: term() | undefined,  %% Python context for affinity
    started = false :: boolean(),
    supported = unknown :: boolean() | unknown
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

%% @doc Run lifespan shutdown protocol.
-spec shutdown() -> ok | {error, term()}.
shutdown() ->
    gen_server:call(?SERVER, shutdown, infinity).

%% @doc Get the lifespan state (shared across requests).
%% Uses ETS cache for fast concurrent reads.
-spec get_state() -> map().
get_state() ->
    case ets:lookup(?CACHE_TABLE, lifespan_state) of
        [{lifespan_state, State}] -> State;
        [] -> #{}
    end.

%% @doc Check if lifespan is running.
-spec is_running() -> boolean().
is_running() ->
    case ets:lookup(?CACHE_TABLE, started) of
        [{started, Started}] -> Started;
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

    %% Create a dedicated Python context for ASGI affinity
    %% This ensures module-level state persists across requests
    PyContext = case py:bind(new) of
        {ok, Ctx} -> Ctx;
        _ -> undefined
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
    %% Unbind the context
    catch py:unbind(PyContext),
    ok;
terminate(_Reason, #state{py_context = PyContext}) ->
    %% Just unbind context if lifespan not started
    catch py:unbind(PyContext),
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
                       [AppModule, AppCallable, TimeoutMs], #{}, TimeoutMs + 5000);
            Ctx ->
                py:ctx_call(Ctx, hornbeam_lifespan_runner, startup,
                           [AppModule, AppCallable, TimeoutMs], #{}, TimeoutMs + 5000)
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
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> ?DEFAULT_TIMEOUT;
        T -> min(T, 10000)  % Cap shutdown timeout
    end,

    try
        %% Use context-aware call for affinity
        Result = case PyContext of
            undefined ->
                py:call(hornbeam_lifespan_runner, shutdown,
                       [AppModule, AppCallable], #{}, TimeoutMs);
            Ctx ->
                py:ctx_call(Ctx, hornbeam_lifespan_runner, shutdown,
                           [AppModule, AppCallable], #{}, TimeoutMs)
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

handle_shutdown_response(Response) ->
    case maps:get(<<"type">>, Response, undefined) of
        <<"lifespan.shutdown.complete">> ->
            ok;
        _ ->
            %% Accept any response during shutdown
            ok
    end.
