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

%%% @doc Hornbeam top-level supervisor.
%%%
%%% Supervises all hornbeam services:
%%% - hornbeam_config: Configuration management
%%% - hornbeam_state: Shared state ETS
%%% - hornbeam_tasks: Async task spawning
%%% - hornbeam_callbacks: Erlang callback registry
%%% - hornbeam_pubsub: Pub/sub messaging
%%% - hornbeam_lifespan: ASGI lifespan management
%%% - hornbeam_hooks: Hooks-style execution API
%%% - hornbeam_channel_registry: Channel topic pattern matching
%%% - hornbeam_presence: Distributed presence tracking (CRDT)
-module(hornbeam_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },

    Children = [
        #{
            id => hornbeam_config,
            start => {hornbeam_config, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_config]
        },
        #{
            id => hornbeam_state,
            start => {hornbeam_state, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_state]
        },
        #{
            id => hornbeam_tasks,
            start => {hornbeam_tasks, start_link, []},
            restart => permanent,
            shutdown => 10000,
            type => worker,
            modules => [hornbeam_tasks]
        },
        #{
            id => hornbeam_callbacks,
            start => {hornbeam_callbacks, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_callbacks]
        },
        #{
            id => hornbeam_pubsub,
            start => {hornbeam_pubsub, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_pubsub]
        },
        #{
            id => hornbeam_lifespan,
            start => {hornbeam_lifespan, start_link, []},
            restart => permanent,
            shutdown => 10000,
            type => worker,
            modules => [hornbeam_lifespan]
        },
        #{
            id => hornbeam_hooks,
            start => {hornbeam_hooks, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_hooks]
        },
        #{
            id => hornbeam_channel_registry,
            start => {hornbeam_channel_registry, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_channel_registry]
        },
        #{
            id => hornbeam_presence,
            start => {hornbeam_presence, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [hornbeam_presence]
        }
    ],

    {ok, {SupFlags, Children}}.
