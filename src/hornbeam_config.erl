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

%%% @doc Hornbeam configuration management.
%%%
%%% This module manages configuration for the hornbeam server.
%%% Configuration is stored in ETS for fast concurrent access.
%%%
%%% == Configuration Options ==
%%%
%%% === Server ===
%%% - bind: Address to bind to (default: "127.0.0.1:8000")
%%% - ssl: Enable SSL/TLS (default: false)
%%% - certfile: Path to SSL certificate file
%%% - keyfile: Path to SSL private key file
%%%
%%% === Protocol ===
%%% - worker_class: wsgi or asgi (default: wsgi)
%%% - http_version: List of supported HTTP versions (default: ['HTTP/1.1', 'HTTP/2'])
%%%
%%% === Workers ===
%%% - workers: Number of Python workers (default: 4)
%%% - timeout: Request timeout in ms (default: 30000)
%%% - keepalive: Keep-alive timeout in seconds (default: 2)
%%% - max_requests: Max requests per worker before restart (default: 1000)
%%% - preload_app: Preload app before forking workers (default: false)
%%%
%%% === Request Limits ===
%%% - max_request_line_size: Max request line size (default: 4094)
%%% - max_header_size: Max header size (default: 8190)
%%% - max_headers: Max number of headers (default: 100)
%%%
%%% === ASGI ===
%%% - root_path: ASGI root_path (default: "")
%%% - lifespan: Lifespan protocol mode: auto, on, off (default: auto)
%%% - lifespan_timeout: Lifespan startup/shutdown timeout in ms (default: 30000)
%%%
%%% === WebSocket ===
%%% - websocket_timeout: WebSocket idle timeout in ms (default: 60000)
%%% - websocket_max_frame_size: Max WebSocket frame size (default: 16MB)
%%%
%%% === Python ===
%%% - pythonpath: Additional Python paths (default: [".", "examples"])
%%% - venv: Virtual environment path (default: undefined)
-module(hornbeam_config).

-behaviour(gen_server).

-export([
    start_link/0,
    get_config/0,
    get_config/1,
    get_config/2,
    set_config/1,
    set_config/2,
    update_config/1,
    defaults/0
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
-define(TABLE, hornbeam_config_table).

-record(state, {}).

%%% ============================================================================
%%% API
%%% ============================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Get all configuration.
-spec get_config() -> map().
get_config() ->
    case ets:lookup(?TABLE, config) of
        [{config, Config}] -> Config;
        [] -> defaults()
    end.

%% @doc Get a configuration value.
-spec get_config(atom()) -> term().
get_config(Key) ->
    Config = get_config(),
    maps:get(Key, Config, undefined).

%% @doc Get a configuration value with default.
-spec get_config(atom(), term()) -> term().
get_config(Key, Default) ->
    Config = get_config(),
    maps:get(Key, Config, Default).

%% @doc Set the entire configuration.
-spec set_config(map()) -> ok.
set_config(Config) when is_map(Config) ->
    gen_server:call(?SERVER, {set_config, Config}).

%% @doc Set a configuration value.
-spec set_config(atom(), term()) -> ok.
set_config(Key, Value) ->
    gen_server:call(?SERVER, {set_config_key, Key, Value}).

%% @doc Update configuration with new values (merge).
-spec update_config(map()) -> ok.
update_config(Updates) when is_map(Updates) ->
    gen_server:call(?SERVER, {update_config, Updates}).

%% @doc Get default configuration.
-spec defaults() -> map().
defaults() ->
    #{
        %% Server
        bind => <<"127.0.0.1:8000">>,
        ssl => false,
        certfile => undefined,
        keyfile => undefined,

        %% Protocol
        worker_class => wsgi,
        http_version => ['HTTP/1.1', 'HTTP/2'],

        %% Workers
        workers => 4,
        timeout => 30000,
        keepalive => 2,
        max_requests => 1000,
        preload_app => false,

        %% Request limits
        max_request_line_size => 4094,
        max_header_size => 8190,
        max_headers => 100,

        %% ASGI
        root_path => <<>>,
        lifespan => auto,
        lifespan_timeout => 30000,  %% Lifespan startup/shutdown timeout in ms

        %% WebSocket
        websocket_timeout => 60000,
        websocket_max_frame_size => 16777216,  % 16MB

        %% Python
        pythonpath => [<<".">>, <<"examples">>],
        venv => undefined
    }.

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Create ETS table for configuration
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        {read_concurrency, true}
    ]),

    %% Load configuration from application env, merged with defaults
    Defaults = defaults(),
    EnvConfig = load_app_env(),
    Config = maps:merge(Defaults, EnvConfig),
    ets:insert(?TABLE, {config, Config}),

    {ok, #state{}}.

handle_call({set_config, Config}, _From, State) ->
    %% Merge with defaults to ensure all keys present
    MergedConfig = maps:merge(defaults(), Config),
    ets:insert(?TABLE, {config, MergedConfig}),
    {reply, ok, State};

handle_call({set_config_key, Key, Value}, _From, State) ->
    Config = get_config(),
    NewConfig = Config#{Key => Value},
    ets:insert(?TABLE, {config, NewConfig}),
    {reply, ok, State};

handle_call({update_config, Updates}, _From, State) ->
    Config = get_config(),
    NewConfig = maps:merge(Config, Updates),
    ets:insert(?TABLE, {config, NewConfig}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

load_app_env() ->
    Keys = [
        %% Server
        bind, ssl, certfile, keyfile,
        %% Protocol
        worker_class, http_version,
        %% Workers
        workers, timeout, keepalive, max_requests, preload_app,
        %% Request limits
        max_request_line_size, max_header_size, max_headers,
        %% ASGI
        root_path, lifespan, lifespan_timeout,
        %% WebSocket
        websocket_timeout, websocket_max_frame_size,
        %% Python
        pythonpath, venv
    ],
    lists:foldl(fun(Key, Acc) ->
        case application:get_env(hornbeam, Key) of
            {ok, Value} -> Acc#{Key => Value};
            undefined -> Acc
        end
    end, #{}, Keys).
