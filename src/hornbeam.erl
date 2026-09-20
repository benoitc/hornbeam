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
%%% for Python execution and livery for HTTP handling.
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
%%%     num_contexts => 4
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
%%%         {"/api", "api:app", #{worker_class => asgi, num_contexts => 4}},
%%%         {"/admin", "admin:app", #{worker_class => wsgi}},
%%%         {"/", "frontend:app", #{worker_class => wsgi}}
%%%     ],
%%%     routes => [{<<"GET">>, "/health", fun health_handler:handle/1}]  %% optional Erlang handlers
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
    info/0,
    is_running/0,
    register_function/2,
    register_function/3,
    unregister_function/1
]).

-type app_spec() :: string() | binary().
-type mount_spec() :: {Prefix :: string() | binary(), AppSpec :: app_spec(), Opts :: map()}.
-type options() :: #{
    bind => string() | binary(),
    num_contexts => pos_integer(),
    num_acceptors => pos_integer(),
    worker_class => wsgi | asgi,
    http_version => [http_version()],
    context_mode => worker | owngil,
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
    max_body => non_neg_integer() | infinity,
    routes => [route()],
    %% SSL/TLS
    ssl => boolean(),
    certfile => string() | binary() | undefined,
    keyfile => string() | binary() | undefined,
    cacertfile => string() | binary() | undefined,
    %% UDP port for the HTTP/3 listener; defaults to the `bind' port
    http3_port => inet:port_number(),
    %% HTTP lifecycle hooks
    hooks => #{
        on_request => fun((map()) -> map()),
        on_response => fun((map()) -> map()),
        on_error => fun((term(), map()) -> {integer(), binary()})
    }
}.
-type route() ::
    {Method :: binary() | '_', Pattern :: binary() | string(),
     Handler :: fun((term()) -> term()) | {module(), atom()}} |
    {Method :: binary() | '_', Pattern :: binary() | string(),
     Handler :: fun((term()) -> term()) | {module(), atom()}, Meta :: map()}.
%% `HTTP/2' and `HTTP/3' are TLS-only, so they require `ssl => true'.
-type http_version() :: 'HTTP/1.1' | 'HTTP/2' | 'HTTP/3'.
-type multi_app_config() :: #{
    mounts := [mount_spec()],
    routes => [route()],
    bind => string() | binary(),
    num_acceptors => pos_integer(),
    http_version => [http_version()],
    pythonpath => [string() | binary()],
    venv => string() | binary() | undefined,
    %% SSL/TLS
    ssl => boolean(),
    certfile => string() | binary() | undefined,
    keyfile => string() | binary() | undefined,
    cacertfile => string() | binary() | undefined,
    http3_port => inet:port_number(),
    %% HTTP lifecycle hooks
    hooks => #{
        on_request => fun((map()) -> map()),
        on_response => fun((map()) -> map()),
        on_error => fun((term(), map()) -> {integer(), binary()})
    }
}.

-export_type([app_spec/0, options/0, mount_spec/0, multi_app_config/0, route/0,
              http_version/0]).

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
%%   <li>`num_contexts' - Number of Python contexts (default: schedulers)</li>
%%   <li>`num_acceptors' - Number of HTTP acceptor processes (default: 100)</li>
%%   <li>`worker_class' - wsgi or asgi (default: wsgi)</li>
%%   <li>`http_version' - HTTP versions to serve (default: ['HTTP/1.1']).
%%       `'HTTP/2'' and `'HTTP/3'' are TLS-only and require `ssl => true'.
%%       `['HTTP/1.1', 'HTTP/2']' serves both from the `bind' port by ALPN;
%%       `'HTTP/3'' adds a QUIC listener on the same port number over UDP</li>
%%   <li>`timeout' - Request timeout in ms (default: 30000)</li>
%%   <li>`keepalive' - Keep-alive timeout in seconds (default: 2)</li>
%%   <li>`max_requests' - Max requests per worker before restart (default: 1000)</li>
%%   <li>`max_concurrent' - Max concurrent requests queued (default: 10000)</li>
%%   <li>`preload_app' - Preload app in all contexts at startup (default: true)</li>
%%   <li>`pythonpath' - Additional Python paths (default: ["."])</li>
%%   <li>`venv' - Virtual environment path (default: undefined)</li>
%%   <li>`lifespan' - Lifespan protocol: auto, on, off (default: auto)</li>
%%   <li>`lifespan_timeout' - Lifespan startup/shutdown timeout in ms (default: 30000)</li>
%%   <li>`websocket_timeout' - WebSocket idle timeout in ms (default: 60000)</li>
%%   <li>`websocket_max_frame_size' - Max WebSocket frame size (default: 16MB)</li>
%%   <li>`routes' - Custom livery routes [{Method, Pattern, Handler}] (default: [])</li>
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
            %% This may restart erlang_python when num_contexts changed.
            case ensure_python_runtime(Config1) of
                ok ->
                    %% Register hornbeam functions for Python callbacks
                    register_python_callbacks(),

                    %% Configure max concurrent requests
                    MaxConcurrent = maps:get(max_concurrent, Config1),
                    py_semaphore:set_max_concurrent(MaxConcurrent),

                    %% Setup Python paths
                    setup_python_paths(Config1),

                    %% Preload app in all contexts for fast access
                    WorkerClass = maps:get(worker_class, Config1),
                    AppModule = maps:get(app_module, Config1),
                    AppCallable = maps:get(app_callable, Config1),
                    hornbeam_context_pool:preload_app(WorkerClass, AppModule, AppCallable),

                    %% Run lifespan startup for ASGI apps
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
    _ = hornbeam_listener:stop_service(),
    ok.

%% @doc Listener status: `#{running := boolean(), listeners := map()}'.
%%
%% `listeners' maps each running protocol (`h1', `h2', `h3') to the list
%% of ports serving it. A list because the mapping is many-to-many: an
%% ALPN listener serves `h1' and `h2' from one port, and `h1' can also be
%% on a second, cleartext port beside it.
-spec info() -> #{running := boolean(), listeners := #{h1 | h2 | h3 => [inet:port_number()]}}.
info() ->
    hornbeam_listener:info().

%% @doc Whether the HTTP listener is running.
-spec is_running() -> boolean().
is_running() ->
    hornbeam_listener:is_running().

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

            %% Calculate max contexts needed (max across all mounts)
            MaxContexts = lists:foldl(fun(Mount, Max) ->
                max(Max, maps:get(num_contexts, Mount, 4))
            end, 4, NormalizedMounts),

            %% Ensure Python runtime with max contexts
            case ensure_python_runtime(GlobalConfig#{num_contexts => MaxContexts}) of
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
                num_contexts => maps:get(num_contexts, GlobalConfig, 4),
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
                num_contexts => maps:get(num_contexts, MountOpts),
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
    %% Get mount_id for per-mount state isolation
    MountId = maps:get(mount_id, Mount),
    %% Build mount-specific options for lifespan startup
    MountOpts = Opts#{
        app_module => maps:get(app_module, Mount),
        app_callable => maps:get(app_callable, Mount)
    },
    case hornbeam_lifespan:startup(MountId, MountOpts) of
        ok -> run_lifespan_for_mounts(Rest, Opts);
        {error, _} = Error -> Error
    end.

%% @private
%% Start the HTTP listener in multi-app mode
start_listener_multi(Config) ->
    %% Multi-app handler state - lookups mount per request
    %% Lifespan state cached at startup (shared across mounts)
    HandlerState = #{
        multi_app => true,
        lifespan_state => hornbeam_lifespan:get_state()
    },
    start_service(Config, HandlerState).

default_config() ->
    #{
        bind => <<"127.0.0.1:8000">>,
        %% num_contexts defaults to erlang:system_info(schedulers) in ensure_python_runtime
        num_acceptors => 100,
        worker_class => wsgi,
        http_version => ['HTTP/1.1'],
        timeout => 30000,
        keepalive => 2,
        max_requests => 1000,
        max_concurrent => 10000,  % High limit for concurrent requests queued
        preload_app => true,
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
    NumContexts = maps:get(num_contexts, Config, erlang:system_info(schedulers)),
    ContextMode = maps:get(context_mode, Config, worker),
    ok = application:set_env(hornbeam, context_pool_size, NumContexts),
    ok = application:set_env(hornbeam, context_mode, ContextMode),
    case current_context_count() of
        {ok, NumContexts} ->
            ok;
        _ ->
            restart_context_pool()
    end.

restart_context_pool() ->
    %% Restart context pool with new size
    case supervisor:terminate_child(hornbeam_sup, hornbeam_context_pool) of
        ok ->
            case supervisor:restart_child(hornbeam_sup, hornbeam_context_pool) of
                {ok, _} -> ok;
                {ok, _, _} -> ok;
                {error, Reason} -> {error, {context_pool_restart_failed, Reason}}
            end;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            {error, {context_pool_terminate_failed, Reason}}
    end.

current_context_count() ->
    try hornbeam_context_pool:pool_size() of
        N when is_integer(N), N > 0 ->
            {ok, N};
        _ ->
            {error, unknown}
    catch
        _:_ ->
            {error, unavailable}
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
    end, AbsPaths),

    %% Also add paths to all contexts in the pool
    %% This is needed because context_call uses separate Python contexts
    hornbeam_context_pool:add_paths(AbsPaths).

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
    %% Cache frequently accessed config values in handler state to avoid
    %% repeated ETS lookups per request
    %% Lifespan state is fetched once here since it doesn't change after startup
    HandlerState = #{
        worker_class => maps:get(worker_class, Config),
        app_module => maps:get(app_module, Config),
        app_callable => maps:get(app_callable, Config),
        timeout => maps:get(timeout, Config, 30000),
        lifespan_state => hornbeam_lifespan:get_state()
    },
    start_service(Config, HandlerState).

%% @private
%% Build the livery service opts from hornbeam config and start it under
%% the supervised hornbeam_listener owner. The handler state is exposed to
%% request handlers via livery_req:config/1.
start_service(Config, HandlerState0) ->
    {Ip, Port} = parse_bind(maps:get(bind, Config, <<"127.0.0.1:8000">>)),
    Ssl = maps:get(ssl, Config, false),
    Versions = maps:get(http_version, Config, ['HTTP/1.1']),
    BaseOpts = #{
        port => Port,
        ip => Ip,
        acceptors => maps:get(num_acceptors, Config, 100),
        idle_timeout => maps:get(keepalive, Config, 2) * 1000,
        request_timeout => maps:get(timeout, Config, 30000),
        %% No request-body cap by default: hornbeam streamed bodies
        %% unbounded under cowboy; livery's own default is 16 MiB.
        max_body => maps:get(max_body, Config, infinity)
    },
    with_ok([
        fun() -> validate_versions(Versions, Ssl) end,
        fun() -> build_listeners(Versions, Ssl, Config, BaseOpts, HandlerState0) end,
        fun(Listeners) -> merge_routing(Config, Listeners) end
    ]).

%% @private
%% Thread a list of steps, short-circuiting on the first error. The first
%% step takes no argument; each later one takes the previous step's value.
with_ok([First | Rest]) ->
    with_ok(Rest, First()).

with_ok(_Steps, {error, _} = Error) ->
    Error;
with_ok([], Result) ->
    Result;
with_ok([Step | Rest], ok) ->
    with_ok(Rest, Step());
with_ok([Step | Rest], {ok, Value}) ->
    with_ok(Rest, Step(Value)).

%% @private
merge_routing(Config, Listeners) ->
    case build_routing(maps:get(routes, Config, [])) of
        {ok, Routing} ->
            hornbeam_listener:start_service(maps:merge(Routing, Listeners));
        {error, _} = Error ->
            Error
    end.

%% @private
%% `HTTP/2' and `HTTP/3' exist only over TLS, so asking for either without
%% `ssl => true' is rejected rather than quietly served as HTTP/1.1.
validate_versions([], _Ssl) ->
    {error, {invalid_http_version, []}};
validate_versions(Versions, Ssl) when is_list(Versions) ->
    Known = ['HTTP/1.1', 'HTTP/2', 'HTTP/3'],
    case [V || V <- Versions, not lists:member(V, Known)] of
        [Bad | _] ->
            {error, {invalid_http_version, Bad}};
        [] when not Ssl ->
            case [V || V <- Versions, V =/= 'HTTP/1.1'] of
                [NeedsTls | _] -> {error, {http_version_requires_ssl, NeedsTls}};
                [] -> ok
            end;
        [] ->
            ok
    end;
validate_versions(Other, _Ssl) ->
    {error, {invalid_http_version, Other}}.

%% @private
%% One livery listener entry per wire protocol. Each carries its own
%% `config' (the handler state), because `server_scheme' differs between a
%% cleartext and a TLS listener in the same service and livery lets a
%% per-listener config override the service-wide one.
build_listeners(Versions, Ssl, Config, BaseOpts, HandlerState) ->
    H1 = lists:member('HTTP/1.1', Versions),
    H2 = lists:member('HTTP/2', Versions),
    H3 = lists:member('HTTP/3', Versions),
    Limits = limit_opts(Config),
    with_ok([
        fun() -> {ok, #{}} end,
        fun(Acc) -> add_tcp_or_tls(Acc, H1, H2, Ssl, Config, BaseOpts, Limits, HandlerState) end,
        fun(Acc) -> add_h3(Acc, H3, Config, BaseOpts, HandlerState) end
    ]).

%% @private
%% Without HTTP/2 the `bind' port is an h1 listener, cleartext or TLS. With
%% it, the port becomes livery's ALPN listener: `[h2, http1]' serves both
%% and prefers h2, `[h2]' alone is h2-only.
add_tcp_or_tls(Acc, false, false, _Ssl, _Config, _BaseOpts, _Limits, _HandlerState) ->
    {ok, Acc};
add_tcp_or_tls(Acc, true, false, false, _Config, BaseOpts, Limits, HandlerState) ->
    Opts = maps:merge(BaseOpts, Limits),
    {ok, Acc#{http => Opts#{config => listener_state(HandlerState, <<"http">>, BaseOpts)}}};
add_tcp_or_tls(Acc, true, false, true, Config, BaseOpts, Limits, HandlerState) ->
    case tls_opts(Config) of
        {ok, Tls} ->
            Opts = maps:merge(maps:merge(BaseOpts, Limits), Tls),
            {ok, Acc#{http => Opts#{
                transport => ssl,
                config => listener_state(HandlerState, <<"https">>, BaseOpts)
            }}};
        {error, _} = Error ->
            Error
    end;
add_tcp_or_tls(Acc, H1, true, true, Config, BaseOpts, Limits, HandlerState) ->
    Alpn = case H1 of
        true -> [h2, http1];
        false -> [h2]
    end,
    case tls_opts(Config) of
        {ok, Tls} ->
            Opts = maps:merge(maps:merge(BaseOpts, Limits), Tls),
            {ok, Acc#{https => Opts#{
                alpn => Alpn,
                config => listener_state(HandlerState, <<"https">>, BaseOpts)
            }}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% HTTP/3 is QUIC over UDP, so it can hold the same port number as the TCP
%% listener beside it. livery derives a stable listener name from the port.
add_h3(Acc, false, _Config, _BaseOpts, _HandlerState) ->
    {ok, Acc};
add_h3(Acc, true, Config, BaseOpts, HandlerState) ->
    case tls_der(Config) of
        {ok, #{cert := Cert, key := Key}} ->
            Port = case maps:get(http3_port, Config, undefined) of
                undefined -> maps:get(port, BaseOpts);
                Explicit -> Explicit
            end,
            H3Opts = #{
                port => Port,
                ip => maps:get(ip, BaseOpts),
                max_body => maps:get(max_body, BaseOpts),
                cert => Cert,
                key => Key,
                config => listener_state(HandlerState, <<"https">>, BaseOpts#{port => Port})
            },
            {ok, Acc#{http3 => H3Opts, alt_svc => advertise}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% `livery_req:scheme/1' reports `<<"http">>' on HTTP/1.1 even under TLS,
%% so the scheme a listener serves is recorded here per listener rather
%% than once per service.
listener_state(HandlerState, Scheme, BaseOpts) ->
    HandlerState#{
        server_scheme => Scheme,
        server_port => maps:get(port, BaseOpts)
    }.

%% @private
%% hornbeam's limit names predate livery; map them onto h1's.
limit_opts(Config) ->
    #{
        max_request_line_size => maps:get(max_request_line_size, Config, 4094),
        max_header_value_size => maps:get(max_header_size, Config, 8190),
        max_headers => maps:get(max_headers, Config, 100)
    }.

%% @private
%% TLS material as file paths, which is what livery's h1 and h2 listeners take.
tls_opts(Config) ->
    case cert_key_files(Config) of
        {ok, CertFile, KeyFile} ->
            SslOpts = case maps:get(cacertfile, Config, undefined) of
                undefined -> [];
                CaCertFile -> [{cacertfile, ensure_list(CaCertFile)}]
            end,
            {ok, #{
                cert => ensure_list(CertFile),
                key => ensure_list(KeyFile),
                ssl_opts => SslOpts
            }};
        {error, _} = Error ->
            Error
    end.

%% @private
%% The h3 listener takes DER instead: the certificate as raw DER bytes and
%% the private key as a decoded key term.
tls_der(Config) ->
    case cert_key_files(Config) of
        {ok, CertFile, KeyFile} ->
            with_ok([
                fun() -> read_pem(certfile, CertFile) end,
                fun(CertEntries) ->
                    case [D || {'Certificate', D, _} <- CertEntries] of
                        [Der | _] -> {ok, Der};
                        [] -> {error, {no_certificate_in_pem, CertFile}}
                    end
                end,
                fun(CertDer) ->
                    case read_pem(keyfile, KeyFile) of
                        {ok, KeyEntries} -> decode_key(KeyEntries, KeyFile, CertDer);
                        {error, _} = Error -> Error
                    end
                end
            ]);
        {error, _} = Error ->
            Error
    end.

%% @private
cert_key_files(Config) ->
    case {maps:get(certfile, Config, undefined), maps:get(keyfile, Config, undefined)} of
        {undefined, _} -> {error, {missing_ssl_option, certfile}};
        {_, undefined} -> {error, {missing_ssl_option, keyfile}};
        {CertFile, KeyFile} -> {ok, CertFile, KeyFile}
    end.

%% @private
read_pem(Which, File) ->
    case file:read_file(File) of
        {ok, Pem} ->
            case public_key:pem_decode(Pem) of
                [] -> {error, {empty_pem, Which, File}};
                Entries -> {ok, Entries}
            end;
        {error, Reason} ->
            {error, {unreadable_pem, Which, File, Reason}}
    end.

%% @private
%% quic wants the key as a decoded record, not as DER bytes.
decode_key(Entries, KeyFile, CertDer) ->
    KeyTypes = ['RSAPrivateKey', 'ECPrivateKey', 'PrivateKeyInfo'],
    case [{T, D} || {T, D, not_encrypted} <- Entries, lists:member(T, KeyTypes)] of
        [{Type, Der} | _] ->
            {ok, #{cert => CertDer, key => public_key:der_decode(Type, Der)}};
        [] ->
            {error, {no_private_key_in_pem, KeyFile}}
    end.

%% @private
%% No custom routes: hand every request to the catch-all handler. With
%% routes, compile a livery router with the catch-all as wildcard fallback
%% so custom routes take precedence, as before.
build_routing([]) ->
    {ok, #{handler => fun hornbeam_handler:handle/1}};
build_routing(Routes) when is_list(Routes) ->
    try
        Entries = [validate_route(R) || R <- Routes],
        Fallback = {'_', <<"/*hb_rest">>, fun hornbeam_handler:handle/1},
        {ok, #{router => livery_router:compile(Entries ++ [Fallback])}}
    catch
        throw:{invalid_route, _} = Reason ->
            {error, Reason}
    end;
build_routing(Other) ->
    {error, {invalid_routes, Other}}.

%% @private
%% Routes use livery shapes: {Method | '_', Pattern, Handler[, Meta]} with
%% Handler a fun/1 or {Module, Function}. The old cowboy
%% {Path, HandlerModule, Opts} shape is rejected.
validate_route({Method, Pattern, Handler}) ->
    {validate_route_method(Method), validate_route_pattern(Pattern),
     validate_route_handler(Handler)};
validate_route({Method, Pattern, Handler, Meta}) when is_map(Meta) ->
    {validate_route_method(Method), validate_route_pattern(Pattern),
     validate_route_handler(Handler), Meta};
validate_route(Route) ->
    throw({invalid_route, Route}).

%% @private
validate_route_method('_') -> '_';
validate_route_method(M) when is_binary(M) -> M;
validate_route_method(M) -> throw({invalid_route, {method, M}}).

%% @private
validate_route_pattern(P) when is_binary(P) -> P;
validate_route_pattern(P) when is_list(P) -> list_to_binary(P);
validate_route_pattern(P) -> throw({invalid_route, {pattern, P}}).

%% @private
validate_route_handler(H) when is_function(H, 1) -> H;
validate_route_handler({M, F} = H) when is_atom(M), is_atom(F) -> H;
validate_route_handler(H) -> throw({invalid_route, {handler, H}}).

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
    %% Multi-arg state ops (get_multi, keys). Python routes here for both.
    py:register_function(hornbeam_state, fun([Action, Args]) ->
        dispatch_state_action(Action, Args)
    end),
    %% Distributed Erlang functions
    py:register_function(hornbeam_dist, fun([Func, Args]) ->
        dispatch_dist_action(Func, Args)
    end),
    %% User-registered callbacks (hornbeam_callbacks). Routes
    %% hornbeam_erlang.call/cast from Python through the gen_server.
    py:register_function(hornbeam_callbacks, fun([Action, Payload]) ->
        dispatch_callbacks_action(Action, Payload)
    end),
    %% Pub/Sub. hornbeam_erlang.publish() routes here.
    py:register_function(hornbeam_pubsub, fun([Action, Payload]) ->
        dispatch_pubsub_action(Action, Payload)
    end),
    ok.

%% Dispatch hornbeam_callbacks actions from Python
dispatch_callbacks_action(<<"call">>, [Name, Args]) ->
    hornbeam_callbacks:call(to_callback_name(Name), Args);
dispatch_callbacks_action(<<"cast">>, [Name, Args]) ->
    hornbeam_callbacks:cast(to_callback_name(Name), Args);
dispatch_callbacks_action(Action, _Payload) ->
    {error, {unknown_callbacks_action, Action}}.

to_callback_name(N) when is_atom(N) -> N;
to_callback_name(N) when is_binary(N) ->
    try binary_to_existing_atom(N, utf8)
    catch error:badarg -> N
    end.

%% Dispatch pub/sub actions from Python
dispatch_pubsub_action(<<"publish">>, [Topic, Message]) ->
    hornbeam_pubsub:publish(Topic, Message);
dispatch_pubsub_action(Action, _Payload) ->
    {error, {unknown_pubsub_action, Action}}.

%% Dispatch multi-key state ops from Python
dispatch_state_action(<<"get_multi">>, [Keys]) ->
    hornbeam_state:get_multi(Keys);
dispatch_state_action(<<"keys">>, []) ->
    hornbeam_state:keys();
dispatch_state_action(<<"keys">>, [Prefix]) ->
    hornbeam_state:keys(Prefix);
dispatch_state_action(Action, _Args) ->
    {error, {unknown_state_action, Action}}.

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
dispatch_hooks_action(<<"stream">>, [AppPath, Action, Args, Kwargs]) ->
    %% Python can't keep a reference to an Erlang fun, so route through
    %% stream_ref/4 which stores the generator inside the gen_server and
    %% returns an opaque reference.
    hornbeam_hooks:stream_ref(ensure_binary(AppPath),
                              ensure_binary(Action), Args, Kwargs);
dispatch_hooks_action(<<"stream_next_ref">>, [GenRef]) ->
    hornbeam_hooks:stream_next_ref(GenRef);
dispatch_hooks_action(Action, Args) ->
    {error, {unknown_hooks_action, Action, Args}}.
