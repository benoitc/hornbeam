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

%%% @doc Basic tests for hornbeam server.
-module(hornbeam_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    test_start_stop/1,
    test_config/1,
    test_register_function/1
]).

all() ->
    [{group, basic}].

groups() ->
    [{basic, [sequence], [
        test_start_stop,
        test_config,
        test_register_function
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    Config.

end_per_suite(_Config) ->
    application:stop(hornbeam),
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    hornbeam:stop(),
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_start_stop(_Config) ->
    %% Test starting the server
    ok = hornbeam:start("hello_wsgi.app:application"),

    %% Verify listener is running
    Listeners = ranch:info(),
    ?assert(lists:keymember(hornbeam_http, 1, Listeners)),

    %% Test stopping
    ok = hornbeam:stop(),

    %% Verify listener is stopped
    Listeners2 = ranch:info(),
    ?assertNot(lists:keymember(hornbeam_http, 1, Listeners2)).

test_config(_Config) ->
    %% Test config management
    hornbeam_config:set_config(#{foo => bar}),
    ?assertEqual(bar, hornbeam_config:get_config(foo)),

    hornbeam_config:set_config(baz, qux),
    ?assertEqual(qux, hornbeam_config:get_config(baz)),

    Config = hornbeam_config:get_config(),
    ?assertEqual(bar, maps:get(foo, Config)),
    ?assertEqual(qux, maps:get(baz, Config)).

test_register_function(_Config) ->
    %% Register a function
    hornbeam:register_function(test_func, fun([X]) -> X * 2 end),

    %% Verify function is registered via py_callback lookup
    {ok, Fun} = py_callback:lookup(<<"test_func">>),
    ?assert(is_function(Fun, 1)),

    %% Execute the function directly through callback mechanism
    {ok, Result} = py_callback:execute(<<"test_func">>, [21]),
    ?assertEqual(42, Result),

    %% Unregister
    hornbeam:unregister_function(test_func),

    %% Verify unregistration
    ?assertEqual({error, not_found}, py_callback:lookup(<<"test_func">>)).
