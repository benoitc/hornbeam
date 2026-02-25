%% Copyright 2026 Benoit Chesneau
%% Licensed under the Apache License, Version 2.0

%%% @doc Multi-App Demo Application.
%%%
%%% Demonstrates mounting multiple Python applications at different URL prefixes,
%%% each with its own virtual environment:
%%% - /api    -> FastAPI (ASGI) with fastapi venv
%%% - /admin  -> Flask (WSGI)   with flask venv
%%% - /       -> WSGI           with no dependencies
-module(multi_app_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case multi_app_sup:start_link() of
        {ok, Pid} ->
            case setup_and_start() of
                ok -> {ok, Pid};
                {error, Reason} ->
                    io:format("Failed to start: ~p~n", [Reason]),
                    {error, Reason}
            end;
        Error ->
            Error
    end.

stop(_State) ->
    hornbeam:stop(),
    ok.

%% Internal

setup_and_start() ->
    %% Get priv directory for Python apps
    PrivDir = code:priv_dir(multi_app),
    ApiDir = filename:join(PrivDir, "api"),
    AdminDir = filename:join(PrivDir, "admin"),
    FrontendDir = filename:join(PrivDir, "frontend"),

    io:format("~n"),
    io:format("========================================~n"),
    io:format("  Hornbeam Multi-App Demo~n"),
    io:format("========================================~n"),
    io:format("~n"),

    %% Setup venvs for each app
    io:format("Setting up virtual environments...~n"),
    ApiVenv = filename:join(ApiDir, "venv"),
    AdminVenv = filename:join(AdminDir, "venv"),

    ok = ensure_venv(ApiDir, ApiVenv),
    ok = ensure_venv(AdminDir, AdminVenv),

    io:format("~n"),
    io:format("Starting with mounts:~n"),
    io:format("  /api    -> FastAPI (ASGI) [venv: ~s]~n", [ApiVenv]),
    io:format("  /admin  -> Flask (WSGI)   [venv: ~s]~n", [AdminVenv]),
    io:format("  /       -> Frontend (WSGI) [no venv]~n"),
    io:format("~n"),

    Result = hornbeam:start(#{
        mounts => [
            %% FastAPI API (ASGI) with its own venv
            {"/api", "api_app:app", #{
                worker_class => asgi,
                workers => 4,
                timeout => 30000,
                venv => ApiVenv,
                pythonpath => [ApiDir]
            }},
            %% Flask Admin (WSGI) with its own venv
            {"/admin", "admin_app:application", #{
                worker_class => wsgi,
                workers => 2,
                timeout => 30000,
                venv => AdminVenv,
                pythonpath => [AdminDir]
            }},
            %% Frontend (WSGI) - no dependencies, just pythonpath
            {"/", "frontend_app:application", #{
                worker_class => wsgi,
                workers => 2,
                timeout => 30000,
                pythonpath => [FrontendDir]
            }}
        ],
        bind => "[::]:8000"
    }),

    case Result of
        ok ->
            io:format("Server started at http://localhost:8000~n"),
            io:format("~n"),
            io:format("Try:~n"),
            io:format("  curl http://localhost:8000/          # Frontend~n"),
            io:format("  curl http://localhost:8000/api       # API root~n"),
            io:format("  curl http://localhost:8000/api/items # List items~n"),
            io:format("  curl http://localhost:8000/admin     # Admin root~n"),
            io:format("~n"),
            ok;
        {error, _} = Error ->
            Error
    end.

%% @private
%% Ensure a virtual environment exists and has dependencies installed
ensure_venv(AppDir, VenvPath) ->
    ReqFile = filename:join(AppDir, "requirements.txt"),
    case filelib:is_dir(VenvPath) of
        true ->
            io:format("  Venv exists: ~s~n", [VenvPath]),
            ok;
        false ->
            io:format("  Creating venv: ~s~n", [VenvPath]),
            %% Create venv
            Cmd1 = io_lib:format("python3 -m venv ~s", [VenvPath]),
            case os:cmd(lists:flatten(Cmd1)) of
                "" ->
                    %% Install requirements if file exists
                    case filelib:is_file(ReqFile) of
                        true ->
                            io:format("  Installing requirements from ~s~n", [ReqFile]),
                            PipPath = filename:join([VenvPath, "bin", "pip"]),
                            Cmd2 = io_lib:format("~s install -q -r ~s", [PipPath, ReqFile]),
                            os:cmd(lists:flatten(Cmd2)),
                            ok;
                        false ->
                            ok
                    end;
                Error ->
                    io:format("  Error creating venv: ~s~n", [Error]),
                    {error, venv_creation_failed}
            end
    end.
