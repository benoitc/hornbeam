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
%%% 1. Server sends: `{type: "lifespan.startup"}`
%%% 2. App responds: `{type: "lifespan.startup.complete"}` or
%%%                  `{type: "lifespan.startup.failed", message: "..."}`
%%%
%%% Shutdown:
%%% 1. Server sends: `{type: "lifespan.shutdown"}`
%%% 2. App responds: `{type: "lifespan.shutdown.complete"}`
%%%
%%% == Configuration ==
%%%
%%% The lifespan setting can be:
%%% - `auto`: Detect if app supports lifespan (default)
%%% - `on`: Require lifespan support, fail if not supported
%%% - `off`: Disable lifespan protocol
-module(hornbeam_lifespan).

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    startup/0,
    startup/1,
    shutdown/0,
    get_state/0,
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

-record(state, {
    app_module :: binary() | undefined,
    app_callable :: binary() | undefined,
    lifespan_mode :: auto | on | off,
    lifespan_state :: map(),
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
-spec get_state() -> map().
get_state() ->
    gen_server:call(?SERVER, get_state).

%% @doc Check if lifespan is running.
-spec is_running() -> boolean().
is_running() ->
    gen_server:call(?SERVER, is_running).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init(Opts) ->
    LifespanMode = maps:get(lifespan, Opts, auto),
    {ok, #state{
        lifespan_mode = LifespanMode,
        lifespan_state = #{}
    }}.

handle_call({startup, Opts}, _From, State) ->
    AppModule = hornbeam_config:get_config(app_module),
    AppCallable = hornbeam_config:get_config(app_callable),
    LifespanMode = maps:get(lifespan, Opts, State#state.lifespan_mode),

    case LifespanMode of
        off ->
            {reply, ok, State#state{started = true, supported = false}};
        _ ->
            %% Try to run lifespan startup
            case run_startup(AppModule, AppCallable) of
                {ok, LifespanState} ->
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
    {reply, ok, State#state{started = false}};

handle_call(shutdown, _From, #state{app_module = AppModule,
                                     app_callable = AppCallable} = State) ->
    Result = run_shutdown(AppModule, AppCallable),
    {reply, Result, State#state{started = false, lifespan_state = #{}}};

handle_call(get_state, _From, #state{lifespan_state = LifespanState} = State) ->
    {reply, LifespanState, State};

handle_call(is_running, _From, #state{started = Started} = State) ->
    {reply, Started, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{started = true, supported = true,
                          app_module = AppModule,
                          app_callable = AppCallable}) ->
    %% Run shutdown on terminate
    _ = run_shutdown(AppModule, AppCallable),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

run_startup(AppModule, AppCallable) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> ?DEFAULT_TIMEOUT;
        T -> T
    end,

    try
        case py:call(hornbeam_lifespan_runner, startup,
                     [AppModule, AppCallable], #{}, TimeoutMs) of
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

run_shutdown(AppModule, AppCallable) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> ?DEFAULT_TIMEOUT;
        T -> min(T, 10000)  % Cap shutdown timeout
    end,

    try
        case py:call(hornbeam_lifespan_runner, shutdown,
                     [AppModule, AppCallable], #{}, TimeoutMs) of
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
