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

%%% @doc Startup script for embedding service.
%%%
%%% This module demonstrates how to register Erlang functions that can be
%%% called from Python WSGI applications. It sets up an ETS-backed cache
%%% for embeddings.
-module(start).

-export([main/1, start/0]).

main(_Args) ->
    start().

start() ->
    %% Ensure all applications are started
    application:ensure_all_started(hornbeam),

    %% Create ETS table for embedding cache
    ets:new(embed_cache, [
        named_table,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),

    %% Register cache_get function - returns cached value or none
    hornbeam:register_function(cache_get, fun([Key]) ->
        case ets:lookup(embed_cache, Key) of
            [{_, Value}] -> Value;
            [] -> none
        end
    end),

    %% Register cache_set function - stores value in cache
    hornbeam:register_function(cache_set, fun([Key, Value]) ->
        ets:insert(embed_cache, {Key, Value}),
        none
    end),

    %% Start the server
    hornbeam:start("embedding_service.app:application", #{
        bind => <<"0.0.0.0:8000">>,
        workers => 4,
        pythonpath => [<<"examples/embedding_service">>]
    }).
