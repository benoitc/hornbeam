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

%%% @doc Startup script for Erlang integration demo.
%%%
%%% Demonstrates registering various Erlang functions that can be
%%% called from Python WSGI applications.
-module(start).

-export([main/1, start/0]).

main(_Args) ->
    start().

start() ->
    %% Ensure all applications are started
    application:ensure_all_started(hornbeam),

    %% Create user database (simple ETS for demo)
    ets:new(user_db, [named_table, public]),
    ets:insert(user_db, {<<"1">>, #{
        <<"id">> => <<"1">>,
        <<"name">> => <<"Alice">>,
        <<"email">> => <<"alice@example.com">>
    }}),
    ets:insert(user_db, {<<"2">>, #{
        <<"id">> => <<"2">>,
        <<"name">> => <<"Bob">>,
        <<"email">> => <<"bob@example.com">>
    }}),

    %% Task counter
    ets:new(task_counter, [named_table, public]),
    ets:insert(task_counter, {counter, 0}),

    %% Register get_config - returns application configuration
    hornbeam:register_function(get_config, fun([]) ->
        #{
            <<"app_name">> => <<"erlang_integration_demo">>,
            <<"version">> => <<"1.0.0">>,
            <<"node">> => atom_to_binary(node(), utf8),
            <<"workers">> => hornbeam_config:get_config(workers)
        }
    end),

    %% Register log_request - logs request to console
    hornbeam:register_function(log_request, fun([Method, Path]) ->
        io:format("[REQUEST] ~s ~s~n", [Method, Path]),
        none
    end),

    %% Register lookup_user - lookup user from ETS
    hornbeam:register_function(lookup_user, fun([UserId]) ->
        case ets:lookup(user_db, UserId) of
            [{_, User}] -> User;
            [] -> none
        end
    end),

    %% Register spawn_task - spawn background process
    hornbeam:register_function(spawn_task, fun([TaskData]) ->
        %% Generate task ID
        TaskNum = ets:update_counter(task_counter, counter, 1),
        TaskId = iolist_to_binary(io_lib:format("task-~B", [TaskNum])),

        %% Spawn background process
        spawn(fun() ->
            io:format("[TASK ~s] Started with data: ~p~n", [TaskId, TaskData]),
            timer:sleep(1000),  % Simulate work
            io:format("[TASK ~s] Completed~n", [TaskId])
        end),

        TaskId
    end),

    %% Start the server
    hornbeam:start("erlang_integration.app:application", #{
        bind => <<"0.0.0.0:8000">>,
        workers => 4,
        pythonpath => [<<"examples/erlang_integration">>]
    }).
