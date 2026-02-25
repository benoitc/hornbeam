%% Copyright 2026 Benoit Chesneau
%% Licensed under the Apache License, Version 2.0

%%% @doc Multi-App Demo Supervisor.
-module(multi_app_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% No children - hornbeam manages its own processes
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
