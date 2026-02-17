%% Copyright 2026 Benoit Chesneau
%% Licensed under the Apache License, Version 2.0

%%% @doc ML Caching Demo Application.
%%%
%%% This OTP application demonstrates:
%%% 1. An Erlang process loading a Python ML model
%%% 2. Registering Erlang hooks that call back into Python
%%% 3. Running a FastAPI web app via Hornbeam
%%%
%%% The flow is:
%%% - ml_caching_embedder GenServer initializes Python EmbeddingApp
%%% - Registers "embeddings" hook handler in Erlang
%%% - Starts Hornbeam with FastAPI app
%%% - FastAPI calls execute("embeddings", "embed", ...) which routes through Erlang
-module(ml_caching_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case ml_caching_sup:start_link() of
        {ok, Pid} ->
            %% Start Hornbeam with the FastAPI app
            start_hornbeam(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    hornbeam:stop(),
    ok.

%% Internal

start_hornbeam() ->
    %% Get priv directory for Python path
    PrivDir = code:priv_dir(ml_caching),

    io:format("ML Caching: Starting Hornbeam with app in ~s~n", [PrivDir]),

    hornbeam:start("app:app", #{
        bind => "[::]:8000",
        worker_class => asgi,
        pythonpath => [PrivDir],
        lifespan_timeout => 120000
    }).
