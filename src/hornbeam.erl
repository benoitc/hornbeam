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

%%% @doc Main API for hornbeam WSGI/ASGI server.
%%%
%%% Hornbeam is an Erlang-based WSGI/ASGI server that uses erlang-python
%%% for Python execution and Cowboy for HTTP handling.
%%%
%%% == Quick Start ==
%%%
%%% ```
%%% %% Start with a WSGI application
%%% hornbeam:start("myapp:application").
%%%
%%% %% Start with options
%%% hornbeam:start("myapp:application", #{
%%%     bind => "0.0.0.0:8000",
%%%     workers => 4
%%% }).
%%%
%%% %% Start ASGI app with lifespan
%%% hornbeam:start("myapp:app", #{
%%%     worker_class => asgi,
%%%     lifespan => on
%%% }).
%%%
%%% %% Register Erlang functions callable from Python
%%% hornbeam:register_function(my_func, fun([Arg]) -> process(Arg) end).
%%%
%%% %% Stop the server
%%% hornbeam:stop().
%%% '''
-module(hornbeam).

-export([
    start/1,
    start/2,
    stop/0,
    register_function/2,
    register_function/3,
    unregister_function/1
]).

-type app_spec() :: string() | binary().
-type options() :: #{
    bind => string() | binary(),
    workers => pos_integer(),
    worker_class => wsgi | asgi,
    timeout => pos_integer(),
    keepalive => pos_integer(),
    max_requests => pos_integer(),
    max_concurrent => pos_integer(),
    preload_app => boolean(),
    pythonpath => [string() | binary()],
    lifespan => auto | on | off,
    websocket_timeout => pos_integer(),
    websocket_max_frame_size => pos_integer(),
    routes => [{Path :: binary(), Handler :: module(), Opts :: map()}]
}.

-export_type([app_spec/0, options/0]).

%% @doc Start hornbeam with a WSGI/ASGI application.
%% The application spec is in the format "module:callable" (e.g., "myapp:application").
-spec start(app_spec()) -> ok | {error, term()}.
start(AppSpec) ->
    start(AppSpec, #{}).

%% @doc Start hornbeam with a WSGI/ASGI application and options.
%%
%% Options:
%% <ul>
%%   <li>`bind' - Address to bind to (default: "127.0.0.1:8000")</li>
%%   <li>`workers' - Number of Python workers (default: 4)</li>
%%   <li>`worker_class' - wsgi or asgi (default: wsgi)</li>
%%   <li>`timeout' - Request timeout in ms (default: 30000)</li>
%%   <li>`keepalive' - Keep-alive timeout in seconds (default: 2)</li>
%%   <li>`max_requests' - Max requests per worker before restart (default: 1000)</li>
%%   <li>`max_concurrent' - Max concurrent requests queued (default: 10000)</li>
%%   <li>`preload_app' - Preload app before forking workers (default: false)</li>
%%   <li>`pythonpath' - Additional Python paths (default: ["."])</li>
%%   <li>`lifespan' - Lifespan protocol: auto, on, off (default: auto)</li>
%%   <li>`websocket_timeout' - WebSocket idle timeout in ms (default: 60000)</li>
%%   <li>`websocket_max_frame_size' - Max WebSocket frame size (default: 16MB)</li>
%%   <li>`routes' - Custom Cowboy routes [{Path, Handler, Opts}] (default: [])</li>
%% </ul>
-spec start(app_spec(), options()) -> ok | {error, term()}.
start(AppSpec, Options) ->
    %% Parse application spec
    case parse_app_spec(AppSpec) of
        {ok, Module, Callable} ->
            %% Store configuration
            Config = maps:merge(default_config(), Options),
            Config1 = Config#{
                app_module => Module,
                app_callable => Callable
            },
            hornbeam_config:set_config(Config1),

            %% Register hornbeam functions for Python callbacks
            register_python_callbacks(),

            %% Configure max concurrent requests
            MaxConcurrent = maps:get(max_concurrent, Config1),
            py_semaphore:set_max_concurrent(MaxConcurrent),

            %% Setup Python paths
            setup_python_paths(Config1),

            %% Run lifespan startup for ASGI apps
            WorkerClass = maps:get(worker_class, Config1),
            case maybe_run_lifespan_startup(WorkerClass, Config1) of
                ok ->
                    %% Start the HTTP listener
                    start_listener(Config1);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Stop hornbeam server.
-spec stop() -> ok.
stop() ->
    %% Run lifespan shutdown first
    _ = hornbeam_lifespan:shutdown(),

    %% Stop the HTTP listener
    _ = ranch:stop_listener(hornbeam_http),
    ok.

%% @doc Register an Erlang function to be callable from Python.
%% The function should accept a list of arguments and return a term.
%%
%% Example:
%% ```
%% hornbeam:register_function(cache_get, fun([Key]) ->
%%     case ets:lookup(my_cache, Key) of
%%         [{_, Value}] -> Value;
%%         [] -> none
%%     end
%% end).
%% '''
-spec register_function(Name :: atom() | binary(), Fun :: fun((list()) -> term())) -> ok.
register_function(Name, Fun) ->
    py:register_function(Name, Fun).

%% @doc Register an Erlang module:function to be callable from Python.
-spec register_function(Name :: atom() | binary(), Module :: atom(), Function :: atom()) -> ok.
register_function(Name, Module, Function) ->
    py:register_function(Name, Module, Function).

%% @doc Unregister a previously registered function.
-spec unregister_function(Name :: atom() | binary()) -> ok.
unregister_function(Name) ->
    py:unregister_function(Name).

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

default_config() ->
    #{
        bind => <<"127.0.0.1:8000">>,
        workers => 4,
        worker_class => wsgi,
        timeout => 30000,
        keepalive => 2,
        max_requests => 1000,
        max_concurrent => 10000,  % High limit for concurrent requests queued
        preload_app => false,
        pythonpath => [<<".">>, <<"examples">>],
        lifespan => auto,
        websocket_timeout => 60000,
        websocket_max_frame_size => 16777216  % 16MB
    }.

parse_app_spec(AppSpec) when is_list(AppSpec) ->
    parse_app_spec(list_to_binary(AppSpec));
parse_app_spec(AppSpec) when is_binary(AppSpec) ->
    case binary:split(AppSpec, <<":">>) of
        [Module, Callable] ->
            {ok, Module, Callable};
        [Module] ->
            {ok, Module, <<"application">>};
        _ ->
            {error, {invalid_app_spec, AppSpec}}
    end.

setup_python_paths(Config) ->
    %% Get priv directory for runner modules (ensure absolute path)
    PrivDir = case code:priv_dir(hornbeam) of
        {error, _} ->
            %% Development mode - find priv relative to ebin
            case code:which(?MODULE) of
                non_existing ->
                    {ok, Cwd} = file:get_cwd(),
                    filename:join(Cwd, "priv");
                ModPath ->
                    EbinDir = filename:dirname(ModPath),
                    AppDir = filename:dirname(EbinDir),
                    filename:join(AppDir, "priv")
            end;
        Dir -> Dir
    end,

    %% Ensure priv dir is absolute
    AbsPrivDir = filename:absname(PrivDir),

    %% Build list of absolute paths
    AllPaths = [AbsPrivDir | maps:get(pythonpath, Config)],
    AbsPaths = lists:map(fun(Path) ->
        PathBin = ensure_binary(Path),
        filename:absname(binary_to_list(PathBin))
    end, AllPaths),

    %% Add paths to Python sys.path
    %% Use py:exec which will be processed by a worker
    %% The path will be set for subsequent calls
    lists:foreach(fun(AbsPath) ->
        Code = io_lib:format(
            "import sys; sys.path.insert(0, '~s') if '~s' not in sys.path else None",
            [AbsPath, AbsPath]),
        py:exec(Code)
    end, AbsPaths).

maybe_run_lifespan_startup(asgi, Config) ->
    LifespanMode = maps:get(lifespan, Config, auto),
    case LifespanMode of
        off -> ok;
        _ -> hornbeam_lifespan:startup(#{lifespan => LifespanMode})
    end;
maybe_run_lifespan_startup(wsgi, _Config) ->
    %% WSGI doesn't support lifespan
    ok.

start_listener(Config) ->
    {Ip, Port} = parse_bind(maps:get(bind, Config)),
    WorkerClass = maps:get(worker_class, Config),

    %% Build custom routes (WebSocket handlers, etc.)
    CustomRoutes = maps:get(routes, Config, []),

    %% Default catchall route for Python app
    DefaultRoute = {'_', hornbeam_handler, #{worker_class => WorkerClass}},

    %% Combine custom routes with default (custom routes take precedence)
    AllRoutes = CustomRoutes ++ [DefaultRoute],

    Dispatch = cowboy_router:compile([
        {'_', AllRoutes}
    ]),

    {ok, _} = cowboy:start_clear(hornbeam_http,
        [{port, Port}, {ip, Ip}],
        #{
            env => #{dispatch => Dispatch},
            idle_timeout => maps:get(keepalive, Config) * 1000,
            request_timeout => maps:get(timeout, Config)
        }
    ),
    ok.

parse_bind(Bind) when is_list(Bind) ->
    parse_bind(list_to_binary(Bind));
parse_bind(Bind) when is_binary(Bind) ->
    %% Handle IPv6 with brackets: [::]:8000, [::1]:8000
    case Bind of
        <<"[", Rest/binary>> ->
            case binary:split(Rest, <<"]:">>) of
                [Ipv6, PortBin] ->
                    Port = binary_to_integer(PortBin),
                    IpTuple = parse_ip(Ipv6),
                    {IpTuple, Port};
                _ ->
                    %% Invalid format, default to IPv4 any
                    {{0, 0, 0, 0}, 8000}
            end;
        _ ->
            %% IPv4 format: ip:port or just port
            case binary:split(Bind, <<":">>) of
                [Ip, PortBin] ->
                    Port = binary_to_integer(PortBin),
                    IpTuple = parse_ip(Ip),
                    {IpTuple, Port};
                [PortBin] ->
                    Port = binary_to_integer(PortBin),
                    {{0, 0, 0, 0}, Port}
            end
    end.

parse_ip(<<"0.0.0.0">>) -> {0, 0, 0, 0};
parse_ip(<<"127.0.0.1">>) -> {127, 0, 0, 1};
parse_ip(<<"localhost">>) -> {127, 0, 0, 1};
parse_ip(<<"::">>) -> {0, 0, 0, 0, 0, 0, 0, 0};
parse_ip(<<"::1">>) -> {0, 0, 0, 0, 0, 0, 0, 1};
parse_ip(Ip) ->
    case inet:parse_address(binary_to_list(Ip)) of
        {ok, IpTuple} -> IpTuple;
        {error, _} -> {0, 0, 0, 0}
    end.

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).

%% Register hornbeam functions so Python can call them via erlang.call()
register_python_callbacks() ->
    %% Hook execution
    py:register_function(hornbeam_hooks_execute, fun([AppPath, Action, Args, Kwargs]) ->
        hornbeam_hooks:execute(AppPath, Action, Args, Kwargs)
    end),
    py:register_function(hornbeam_hooks_execute_async, fun([AppPath, Action, Args, Kwargs]) ->
        hornbeam_hooks:execute_async(AppPath, Action, Args, Kwargs)
    end),
    %% State functions
    py:register_function(hornbeam_state_get, fun([Key]) ->
        hornbeam_state:get(Key)
    end),
    py:register_function(hornbeam_state_set, fun([Key, Value]) ->
        hornbeam_state:set(Key, Value)
    end),
    py:register_function(hornbeam_state_delete, fun([Key]) ->
        hornbeam_state:delete(Key)
    end),
    py:register_function(hornbeam_state_incr, fun([Key, Delta]) ->
        hornbeam_state:incr(Key, Delta)
    end),
    py:register_function(hornbeam_state_decr, fun([Key, Delta]) ->
        hornbeam_state:decr(Key, Delta)
    end),
    ok.
