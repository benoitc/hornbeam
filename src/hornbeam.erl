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
%%% %% Multi-app mode - mount different apps at different prefixes
%%% hornbeam:start(#{
%%%     mounts => [
%%%         {"/api", "api:app", #{worker_class => asgi, workers => 4}},
%%%         {"/admin", "admin:app", #{worker_class => wsgi}},
%%%         {"/", "frontend:app", #{worker_class => wsgi}}
%%%     ],
%%%     routes => [{"/health", health_handler, #{}}]  %% optional Erlang handlers
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
-type mount_spec() :: {Prefix :: string() | binary(), AppSpec :: app_spec(), Opts :: map()}.
-type options() :: #{
    bind => string() | binary(),
    workers => pos_integer(),
    num_acceptors => pos_integer(),
    worker_class => wsgi | asgi,
    timeout => pos_integer(),
    keepalive => pos_integer(),
    max_requests => pos_integer(),
    max_concurrent => pos_integer(),
    preload_app => boolean(),
    pythonpath => [string() | binary()],
    venv => string() | binary() | undefined,
    lifespan => auto | on | off,
    lifespan_timeout => pos_integer(),
    websocket_timeout => pos_integer(),
    websocket_max_frame_size => pos_integer(),
    websocket_compress => boolean(),
    routes => [{Path :: binary(), Handler :: module(), Opts :: map()}],
    %% SSL/TLS
    ssl => boolean(),
    certfile => string() | binary() | undefined,
    keyfile => string() | binary() | undefined,
    cacertfile => string() | binary() | undefined,
    %% HTTP lifecycle hooks
    hooks => #{
        on_request => fun((map()) -> map()),
        on_response => fun((map()) -> map()),
        on_error => fun((term(), map()) -> {integer(), binary()})
    }
}.
-type multi_app_config() :: #{
    mounts := [mount_spec()],
    routes => [{Path :: binary(), Handler :: module(), Opts :: map()}],
    bind => string() | binary(),
    num_acceptors => pos_integer(),
    pythonpath => [string() | binary()],
    venv => string() | binary() | undefined,
    %% SSL/TLS
    ssl => boolean(),
    certfile => string() | binary() | undefined,
    keyfile => string() | binary() | undefined,
    cacertfile => string() | binary() | undefined,
    %% HTTP lifecycle hooks
    hooks => #{
        on_request => fun((map()) -> map()),
        on_response => fun((map()) -> map()),
        on_error => fun((term(), map()) -> {integer(), binary()})
    }
}.

-export_type([app_spec/0, options/0, mount_spec/0, multi_app_config/0]).

%% @doc Start hornbeam with a WSGI/ASGI application or multi-app config.
%%
%% For single-app mode, pass the application spec as "module:callable".
%% For multi-app mode, pass a map with 'mounts' key containing mount specs.
-spec start(app_spec() | multi_app_config()) -> ok | {error, term()}.
start(#{mounts := Mounts} = Config) when is_list(Mounts) ->
    %% Multi-app mode
    start_multi(Config);
start(AppSpec) when is_list(AppSpec); is_binary(AppSpec) ->
    %% Single-app mode
    start(AppSpec, #{}).

%% @doc Start hornbeam with a WSGI/ASGI application and options.
%%
%% Options:
%% <ul>
%%   <li>`bind' - Address to bind to (default: "127.0.0.1:8000")</li>
%%   <li>`workers' - Number of Python workers (default: 4)</li>
%%   <li>`num_acceptors' - Number of Cowboy acceptor processes (default: 100)</li>
%%   <li>`worker_class' - wsgi or asgi (default: wsgi)</li>
%%   <li>`timeout' - Request timeout in ms (default: 30000)</li>
%%   <li>`keepalive' - Keep-alive timeout in seconds (default: 2)</li>
%%   <li>`max_requests' - Max requests per worker before restart (default: 1000)</li>
%%   <li>`max_concurrent' - Max concurrent requests queued (default: 10000)</li>
%%   <li>`preload_app' - Preload app before forking workers (default: false)</li>
%%   <li>`pythonpath' - Additional Python paths (default: ["."])</li>
%%   <li>`venv' - Virtual environment path (default: undefined)</li>
%%   <li>`lifespan' - Lifespan protocol: auto, on, off (default: auto)</li>
%%   <li>`lifespan_timeout' - Lifespan startup/shutdown timeout in ms (default: 30000)</li>
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

            %% Initialize HTTP hooks if provided
            Hooks = maps:get(hooks, Config1, #{}),
            hornbeam_http_hooks:set_hooks(Hooks),

            %% Ensure Python runtime matches requested worker count.
            %% This may restart erlang_python when workers changed.
            case ensure_python_runtime(Config1) of
                ok ->
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

%% @private
%% Start in multi-app mode with multiple mounts
start_multi(Config) ->
    %% Validate and normalize mounts
    case validate_mounts(maps:get(mounts, Config), Config) of
        {ok, NormalizedMounts} ->
            %% Register mounts
            hornbeam_mounts:register(NormalizedMounts),

            %% Merge global defaults into config
            GlobalConfig = maps:merge(default_multi_config(), Config),

            %% Store global configuration
            hornbeam_config:set_config(GlobalConfig),

            %% Initialize HTTP hooks if provided
            Hooks = maps:get(hooks, GlobalConfig, #{}),
            hornbeam_http_hooks:set_hooks(Hooks),

            %% Calculate max workers needed (max across all mounts)
            MaxWorkers = lists:foldl(fun(Mount, Max) ->
                max(Max, maps:get(workers, Mount, 4))
            end, 4, NormalizedMounts),

            %% Ensure Python runtime with max workers
            case ensure_python_runtime(GlobalConfig#{workers => MaxWorkers}) of
                ok ->
                    %% Register hornbeam functions for Python callbacks
                    register_python_callbacks(),

                    %% Configure max concurrent requests
                    MaxConcurrent = maps:get(max_concurrent, GlobalConfig, 10000),
                    py_semaphore:set_max_concurrent(MaxConcurrent),

                    %% Setup global Python paths
                    setup_python_paths(GlobalConfig),

                    %% Setup pythonpath for all mounts (needed for lifespan and module loading)
                    setup_mounts_pythonpath(NormalizedMounts),

                    %% Run lifespan startup for ASGI mounts
                    case maybe_run_multi_lifespan_startup(NormalizedMounts, GlobalConfig) of
                        ok ->
                            %% Start the HTTP listener in multi-app mode
                            start_listener_multi(GlobalConfig);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
%% Setup pythonpath for all mounts at startup
setup_mounts_pythonpath(Mounts) ->
    lists:foreach(fun(Mount) ->
        Paths = maps:get(pythonpath, Mount, []),
        lists:foreach(fun(Path) ->
            add_to_sys_path(Path)
        end, Paths)
    end, Mounts).

%% @private
%% Add a path to Python's sys.path if not already present
add_to_sys_path(Path) ->
    PathBin = ensure_binary(Path),
    py:eval(<<"__import__('sys').path.insert(0, p) if p not in __import__('sys').path else None">>,
            #{p => PathBin}).

%% @private
%% Default config for multi-app mode (global settings only)
default_multi_config() ->
    #{
        bind => <<"127.0.0.1:8000">>,
        num_acceptors => 100,
        max_concurrent => 10000,
        pythonpath => [<<".">>, <<"examples">>],
        venv => undefined
    }.

%% @private
%% Validate and normalize mount specs into mount records
validate_mounts(Mounts, GlobalConfig) ->
    try
        Validated = lists:map(fun(MountSpec) ->
            validate_mount(MountSpec, GlobalConfig)
        end, Mounts),
        %% Check for duplicate prefixes
        Prefixes = [maps:get(prefix, M) || M <- Validated],
        case length(Prefixes) =:= length(lists:usort(Prefixes)) of
            true -> {ok, Validated};
            false -> {error, duplicate_mount_prefix}
        end
    catch
        throw:{invalid_mount, Reason} ->
            {error, {invalid_mount, Reason}}
    end.

%% @private
validate_mount({Prefix, AppSpec, Opts}, GlobalConfig) ->
    %% Validate prefix
    PrefixBin = ensure_binary(Prefix),
    case PrefixBin of
        <<"/", _/binary>> -> ok;
        _ -> throw({invalid_mount, {prefix_must_start_with_slash, Prefix}})
    end,
    %% Check for trailing slash (except root)
    case PrefixBin of
        <<"/">> -> ok;
        _ ->
            case binary:last(PrefixBin) of
                $/ -> throw({invalid_mount, {prefix_must_not_end_with_slash, Prefix}});
                _ -> ok
            end
    end,
    %% Parse app spec
    case parse_app_spec(AppSpec) of
        {ok, Module, Callable} ->
            %% Merge global defaults with mount-specific opts
            DefaultOpts = #{
                worker_class => wsgi,
                workers => maps:get(workers, GlobalConfig, 4),
                timeout => maps:get(timeout, GlobalConfig, 30000)
            },
            MountOpts = maps:merge(DefaultOpts, Opts),
            %% Build pythonpath for this mount
            %% Priority: mount pythonpath > mount venv site-packages > global pythonpath
            MountPythonpath = build_mount_pythonpath(MountOpts, GlobalConfig),
            #{
                prefix => PrefixBin,
                app_module => Module,
                app_callable => Callable,
                worker_class => maps:get(worker_class, MountOpts),
                workers => maps:get(workers, MountOpts),
                timeout => maps:get(timeout, MountOpts),
                pythonpath => MountPythonpath
            };
        {error, Reason} ->
            throw({invalid_mount, {invalid_app_spec, AppSpec, Reason}})
    end;
validate_mount(Invalid, _GlobalConfig) ->
    throw({invalid_mount, {invalid_mount_spec, Invalid}}).

%% @private
%% Build the pythonpath for a mount, including venv site-packages if specified
build_mount_pythonpath(MountOpts, _GlobalConfig) ->
    %% Start with mount-specific pythonpath or empty list
    BasePath = case maps:get(pythonpath, MountOpts, undefined) of
        undefined -> [];
        Paths when is_list(Paths) -> [ensure_binary(P) || P <- Paths]
    end,
    %% Add venv site-packages if venv is specified
    VenvPath = case maps:get(venv, MountOpts, undefined) of
        undefined -> [];
        Venv ->
            VenvBin = ensure_binary(Venv),
            %% Get site-packages path for the venv
            SitePackages = get_venv_site_packages(VenvBin),
            case SitePackages of
                undefined -> [];
                Path -> [Path]
            end
    end,
    %% Combine: mount paths + venv site-packages
    %% Note: we don't include global pythonpath as each mount should be isolated
    BasePath ++ VenvPath.

%% @private
%% Get the site-packages directory for a virtualenv
get_venv_site_packages(VenvPath) ->
    %% Try common site-packages locations
    Candidates = [
        %% Linux/macOS
        filename:join([VenvPath, <<"lib">>, <<"python3.14">>, <<"site-packages">>]),
        filename:join([VenvPath, <<"lib">>, <<"python3.13">>, <<"site-packages">>]),
        filename:join([VenvPath, <<"lib">>, <<"python3.12">>, <<"site-packages">>]),
        filename:join([VenvPath, <<"lib">>, <<"python3.11">>, <<"site-packages">>]),
        filename:join([VenvPath, <<"lib">>, <<"python3.10">>, <<"site-packages">>]),
        %% Windows
        filename:join([VenvPath, <<"Lib">>, <<"site-packages">>])
    ],
    find_existing_path(Candidates).

%% @private
find_existing_path([]) -> undefined;
find_existing_path([Path | Rest]) ->
    case filelib:is_dir(Path) of
        true -> Path;
        false -> find_existing_path(Rest)
    end.

%% @private
%% Run lifespan startup for all ASGI mounts
maybe_run_multi_lifespan_startup(Mounts, Config) ->
    AsgiMounts = [M || M <- Mounts, maps:get(worker_class, M) =:= asgi],
    LifespanMode = maps:get(lifespan, Config, auto),
    case {AsgiMounts, LifespanMode} of
        {[], _} -> ok;
        {_, off} -> ok;
        {_, _} ->
            %% For now, run lifespan for all ASGI mounts sequentially
            %% TODO: Could be optimized to run in parallel
            run_lifespan_for_mounts(AsgiMounts, #{lifespan => LifespanMode})
    end.

%% @private
run_lifespan_for_mounts([], _Opts) ->
    ok;
run_lifespan_for_mounts([Mount | Rest], Opts) ->
    %% Store mount info in config temporarily for lifespan
    hornbeam_config:set_config(#{
        app_module => maps:get(app_module, Mount),
        app_callable => maps:get(app_callable, Mount)
    }),
    case hornbeam_lifespan:startup(Opts) of
        ok -> run_lifespan_for_mounts(Rest, Opts);
        {error, _} = Error -> Error
    end.

%% @private
%% Start the HTTP listener in multi-app mode
start_listener_multi(Config) ->
    {Ip, Port} = parse_bind(maps:get(bind, Config)),
    NumAcceptors = maps:get(num_acceptors, Config, 100),

    %% Build custom routes (WebSocket handlers, etc.)
    CustomRoutes = maps:get(routes, Config, []),

    %% Multi-app handler state - lookups mount per request
    HandlerState = #{
        multi_app => true
    },

    %% Default catchall route for Python apps (routes to mounts)
    DefaultRoute = {'_', hornbeam_handler, HandlerState},

    %% Combine custom routes with default (custom routes take precedence)
    AllRoutes = CustomRoutes ++ [DefaultRoute],

    Dispatch = cowboy_router:compile([
        {'_', AllRoutes}
    ]),

    %% Build protocol options including request limits
    ProtoOpts = #{
        env => #{dispatch => Dispatch},
        idle_timeout => maps:get(keepalive, Config, 2) * 1000,
        request_timeout => maps:get(timeout, Config, 30000),
        max_request_line_length => maps:get(max_request_line_size, Config, 4094),
        max_header_value_length => maps:get(max_header_size, Config, 8190),
        max_headers => maps:get(max_headers, Config, 100)
    },

    %% Start with SSL/TLS or plain HTTP
    case maps:get(ssl, Config, false) of
        true ->
            start_tls_listener(Ip, Port, Config, ProtoOpts);
        false ->
            TransportOpts = #{
                num_acceptors => NumAcceptors,
                socket_opts => [{port, Port}, {ip, Ip}]
            },
            {ok, _} = cowboy:start_clear(hornbeam_http,
                TransportOpts, ProtoOpts),
            ok
    end.

default_config() ->
    #{
        bind => <<"127.0.0.1:8000">>,
        workers => 4,
        num_acceptors => 100,
        worker_class => wsgi,
        timeout => 30000,
        keepalive => 2,
        max_requests => 1000,
        max_concurrent => 10000,  % High limit for concurrent requests queued
        preload_app => false,
        pythonpath => [<<".">>, <<"examples">>],
        venv => undefined,
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

ensure_python_runtime(Config) ->
    Workers = maps:get(workers, Config, 4),
    ok = application:set_env(erlang_python, num_workers, Workers),
    case current_python_workers() of
        {ok, Workers} ->
            ok;
        _ ->
            restart_python_runtime()
    end.

current_python_workers() ->
    %% In the new erlang_python architecture (subinterpreters), worker count
    %% is determined by num_contexts in the context supervisor. Check if
    %% contexts are available.
    try py:contexts_started() of
        true ->
            %% Contexts are running, get count from application env
            NumWorkers = application:get_env(erlang_python, num_workers, 4),
            {ok, NumWorkers};
        false ->
            {error, not_started}
    catch
        _:_ ->
            {error, unavailable}
    end.

restart_python_runtime() ->
    case application:stop(erlang_python) of
        ok ->
            start_python_runtime();
        {error, {not_started, erlang_python}} ->
            start_python_runtime();
        {error, Reason} ->
            {error, {python_stop_failed, Reason}}
    end.

start_python_runtime() ->
    case application:start(erlang_python) of
        ok ->
            refresh_lifespan_manager();
        {error, {already_started, erlang_python}} ->
            refresh_lifespan_manager();
        {error, Reason} ->
            {error, {python_start_failed, Reason}}
    end.

refresh_lifespan_manager() ->
    case whereis(hornbeam_lifespan) of
        undefined ->
            ok;
        _ ->
            case supervisor:terminate_child(hornbeam_sup, hornbeam_lifespan) of
                ok ->
                    restart_lifespan_manager();
                {error, not_found} ->
                    ok;
                {error, Reason} ->
                    {error, {lifespan_terminate_failed, Reason}}
            end
    end.

restart_lifespan_manager() ->
    case supervisor:restart_child(hornbeam_sup, hornbeam_lifespan) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, Reason} ->
            {error, {lifespan_restart_failed, Reason}}
    end.

setup_python_paths(Config) ->
    %% Activate virtual environment if specified
    _ = case maps:get(venv, Config, undefined) of
        undefined ->
            ok;
        Venv ->
            VenvBin = ensure_binary(Venv),
            AbsVenv = list_to_binary(filename:absname(binary_to_list(VenvBin))),
            py:activate_venv(AbsVenv)
    end,

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
    NumAcceptors = maps:get(num_acceptors, Config, 100),
    WorkerClass = maps:get(worker_class, Config),

    %% Build custom routes (WebSocket handlers, etc.)
    CustomRoutes = maps:get(routes, Config, []),

    %% Cache frequently accessed config values in handler state to avoid
    %% repeated ETS lookups per request
    HandlerState = #{
        worker_class => WorkerClass,
        app_module => maps:get(app_module, Config),
        app_callable => maps:get(app_callable, Config),
        timeout => maps:get(timeout, Config, 30000)
    },

    %% Default catchall route for Python app
    DefaultRoute = {'_', hornbeam_handler, HandlerState},

    %% Combine custom routes with default (custom routes take precedence)
    AllRoutes = CustomRoutes ++ [DefaultRoute],

    Dispatch = cowboy_router:compile([
        {'_', AllRoutes}
    ]),

    %% Build protocol options including request limits
    ProtoOpts = #{
        env => #{dispatch => Dispatch},
        idle_timeout => maps:get(keepalive, Config) * 1000,
        request_timeout => maps:get(timeout, Config),
        %% Cowboy HTTP options for request limits
        max_request_line_length => maps:get(max_request_line_size, Config, 4094),
        max_header_value_length => maps:get(max_header_size, Config, 8190),
        max_headers => maps:get(max_headers, Config, 100)
    },

    %% Start with SSL/TLS or plain HTTP
    case maps:get(ssl, Config, false) of
        true ->
            start_tls_listener(Ip, Port, Config, ProtoOpts);
        false ->
            TransportOpts = #{
                num_acceptors => NumAcceptors,
                socket_opts => [{port, Port}, {ip, Ip}]
            },
            {ok, _} = cowboy:start_clear(hornbeam_http,
                TransportOpts, ProtoOpts),
            ok
    end.

%% @private
%% Start SSL/TLS listener with certificate configuration
start_tls_listener(Ip, Port, Config, ProtoOpts) ->
    NumAcceptors = maps:get(num_acceptors, Config, 100),
    CertFile = maps:get(certfile, Config, undefined),
    KeyFile = maps:get(keyfile, Config, undefined),
    CaCertFile = maps:get(cacertfile, Config, undefined),
    case {CertFile, KeyFile} of
        {undefined, _} ->
            {error, {missing_ssl_option, certfile}};
        {_, undefined} ->
            {error, {missing_ssl_option, keyfile}};
        _ ->
            SocketOpts = [{port, Port}, {ip, Ip},
                          {certfile, ensure_list(CertFile)},
                          {keyfile, ensure_list(KeyFile)}] ++
                         case CaCertFile of
                             undefined -> [];
                             _ -> [{cacertfile, ensure_list(CaCertFile)}]
                         end,
            TransportOpts = #{
                num_acceptors => NumAcceptors,
                socket_opts => SocketOpts
            },
            {ok, _} = cowboy:start_tls(hornbeam_http, TransportOpts, ProtoOpts),
            ok
    end.

%% @private
ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V).

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
    %% Hook registration (called from Python to register/unregister hooks)
    py:register_function(hornbeam_hooks, fun([Action, Args]) ->
        dispatch_hooks_action(Action, Args)
    end),
    %% Hook execution
    py:register_function(hornbeam_hooks_execute, fun([AppPath, Action, Args, Kwargs]) ->
        hornbeam_hooks:execute(AppPath, Action, Args, Kwargs)
    end),
    py:register_function(hornbeam_hooks_execute_async, fun([AppPath, Action, Args, Kwargs]) ->
        hornbeam_hooks:execute_async(AppPath, Action, Args, Kwargs)
    end),
    py:register_function(hornbeam_hooks_await_result, fun([TaskId, Timeout]) ->
        hornbeam_hooks:await_result(TaskId, Timeout)
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
    %% Distributed Erlang functions
    py:register_function(hornbeam_dist, fun([Func, Args]) ->
        dispatch_dist_action(Func, Args)
    end),
    ok.

%% Dispatch distributed Erlang actions from Python
dispatch_dist_action(<<"rpc_call">>, [Node, Module, Function, Args, Timeout]) ->
    hornbeam_dist:rpc_call(Node, Module, Function, Args, Timeout);
dispatch_dist_action(<<"rpc_cast">>, [Node, Module, Function, Args]) ->
    hornbeam_dist:rpc_cast(Node, Module, Function, Args);
dispatch_dist_action(<<"connected_nodes">>, []) ->
    hornbeam_dist:connected_nodes();
dispatch_dist_action(<<"nodes">>, []) ->
    hornbeam_dist:nodes();
dispatch_dist_action(<<"node">>, []) ->
    hornbeam_dist:node();
dispatch_dist_action(<<"ping">>, [Node]) ->
    hornbeam_dist:ping(Node);
dispatch_dist_action(<<"connect">>, [Node]) ->
    hornbeam_dist:connect(Node);
dispatch_dist_action(<<"disconnect">>, [Node]) ->
    hornbeam_dist:disconnect(Node);
dispatch_dist_action(Action, Args) ->
    {error, {unknown_dist_action, Action, Args}}.

%% Dispatch hooks actions from Python
dispatch_hooks_action(<<"reg_python">>, [AppPath]) ->
    hornbeam_hooks:reg_python(ensure_binary(AppPath));
dispatch_hooks_action(<<"unreg">>, [AppPath]) ->
    hornbeam_hooks:unreg(ensure_binary(AppPath));
dispatch_hooks_action(Action, Args) ->
    {error, {unknown_hooks_action, Action, Args}}.
