%% Copyright 2026 Benoit Chesneau
%% Licensed under the Apache License, Version 2.0

%%% @doc ML Caching Demo Supervisor.
%%%
%%% Supervises the ml_caching_embedder process which manages the
%%% Python embedding model and Erlang hooks.
-module(ml_caching_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 3,
        period => 60
    },

    EmbedderSpec = #{
        id => ml_caching_embedder,
        start => {ml_caching_embedder, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [ml_caching_embedder]
    },

    {ok, {SupFlags, [EmbedderSpec]}}.
