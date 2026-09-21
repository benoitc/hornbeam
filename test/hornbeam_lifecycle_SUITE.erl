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

%%% @doc `hornbeam:stop/0' releases what `start/2' set up.
%%%
%%% The gen_servers holding that state are supervised by the application
%%% rather than by the listener, so their tables and persistent_terms
%%% outlive a service. Before this teardown a second `start/2' in the
%%% same VM inherited the first run's config, hooks, channel handlers and
%%% presence; every case here fails without it.
-module(hornbeam_lifecycle_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    end_per_testcase/2
]).

-export([
    test_restart_in_place/1,
    test_stop_resets_config/1,
    test_stop_clears_hooks/1,
    test_stop_clears_channel_handlers/1,
    test_stop_clears_presence/1,
    test_stop_clears_state/1,
    test_stop_is_idempotent/1,
    test_env_keys_have_defaults/1,
    test_multi_defaults_are_a_subset/1
]).

-define(APP, "hello_wsgi.app:application").

all() ->
    [{group, lifecycle}].

groups() ->
    [{lifecycle, [sequence], [
        test_restart_in_place,
        test_stop_resets_config,
        test_stop_clears_hooks,
        test_stop_clears_channel_handlers,
        test_stop_clears_presence,
        test_stop_clears_state,
        test_stop_is_idempotent,
        test_env_keys_have_defaults,
        test_multi_defaults_are_a_subset
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    Config.

end_per_suite(_Config) ->
    application:stop(hornbeam),
    ok.

end_per_testcase(_TestCase, _Config) ->
    _ = hornbeam:stop(),
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

%% The case the whole teardown exists for: start, stop, start again, in
%% one VM. Fails with `already_started' when stop leaves the listener's
%% service pid behind.
test_restart_in_place(_Config) ->
    ok = hornbeam:start(?APP, #{bind => <<"127.0.0.1:18711">>}),
    ?assert(hornbeam:is_running()),
    ok = hornbeam:stop(),
    ?assertNot(hornbeam:is_running()),

    ok = hornbeam:start(?APP, #{bind => <<"127.0.0.1:18712">>}),
    ?assert(hornbeam:is_running()),
    #{listeners := Listeners} = hornbeam:info(),
    ?assertEqual([18712], maps:get(h1, Listeners, undefined)).

%% A later run must not inherit the earlier run's options. `bind' is the
%% one that bites: a second start silently reusing the first port looks
%% like it worked.
test_stop_resets_config(_Config) ->
    Default = maps:get(bind, hornbeam_config:defaults()),
    ok = hornbeam:start(?APP, #{bind => <<"127.0.0.1:18713">>}),
    ?assertEqual(<<"127.0.0.1:18713">>, hornbeam_config:get_config(bind)),
    ok = hornbeam:stop(),
    ?assertEqual(Default, hornbeam_config:get_config(bind)).

%% Hooks are persistent_terms, so leaving them behind means a later run
%% answers with a handler nobody registered.
test_stop_clears_hooks(_Config) ->
    OnRequest = fun(Req) -> Req end,
    ok = hornbeam:start(?APP, #{bind => <<"127.0.0.1:18714">>,
                                hooks => #{on_request => OnRequest}}),
    ?assertMatch(#{on_request := _}, hornbeam_http_hooks:get_hooks()),
    ok = hornbeam:stop(),
    ?assertEqual(#{}, hornbeam_http_hooks:get_hooks()),

    ok = hornbeam_hooks:reg(<<"/app">>, fun(_, _, _) -> ok end),
    ?assertNotEqual([], hornbeam_hooks:all()),
    ok = hornbeam:stop(),
    ?assertEqual([], hornbeam_hooks:all()).

test_stop_clears_channel_handlers(_Config) ->
    ok = hornbeam_channel_registry:register(<<"room:*">>,
                                            #{module => <<"room:*">>,
                                              type => <<"python">>}),
    ?assertNotEqual([], hornbeam_channel_registry:list_handlers()),
    ok = hornbeam:stop(),
    ?assertEqual([], hornbeam_channel_registry:list_handlers()).

%% Presence holds monitors, so clearing must release them as well as
%% drop the members; otherwise the refs leak and DOWNs arrive for state
%% that no longer exists.
test_stop_clears_presence(_Config) ->
    Pid = spawn(fun() -> receive stop -> ok end end),
    {monitors, Before} = erlang:process_info(whereis(hornbeam_presence), monitors),
    ok = hornbeam_presence:track(<<"room:1">>, Pid, <<"u1">>, #{name => <<"a">>}),
    ?assertMatch(#{<<"u1">> := _}, hornbeam_presence:list(<<"room:1">>)),

    ok = hornbeam:stop(),
    ?assertEqual(#{}, hornbeam_presence:list(<<"room:1">>)),
    {monitors, After} = erlang:process_info(whereis(hornbeam_presence), monitors),
    ?assertEqual(length(Before), length(After)),
    Pid ! stop.

test_stop_clears_state(_Config) ->
    ok = hornbeam_state:set(<<"k">>, <<"v">>),
    ?assertEqual(<<"v">>, hornbeam_state:get(<<"k">>)),
    ok = hornbeam:stop(),
    ?assertEqual(undefined, hornbeam_state:get(<<"k">>)).

%% Stopping what was never started, and stopping twice, both answer ok.
test_stop_is_idempotent(_Config) ->
    ok = hornbeam:stop(),
    ok = hornbeam:stop(),
    ok = hornbeam:start(?APP, #{bind => <<"127.0.0.1:18715">>}),
    ok = hornbeam:stop(),
    ok = hornbeam:stop().

%% An env key with no default is one nothing reads: it silently does
%% nothing, which is how `workers', `max_requests' and `preload_app'
%% survived in the shipped env while the code ignored them.
test_env_keys_have_defaults(_Config) ->
    Defaults = hornbeam_config:defaults(),
    Orphans = [K || K <- hornbeam_config:env_keys(),
                    not maps:is_key(K, Defaults),
                    K =/= num_contexts],   %% owned by erlang_python
    ?assertEqual([], Orphans).

%% Multi-app mode configures a subset of the same options, so it must
%% not carry values of its own that can drift from the defaults.
test_multi_defaults_are_a_subset(_Config) ->
    Defaults = hornbeam_config:defaults(),
    maps:foreach(fun(K, V) ->
        ?assertEqual({K, maps:get(K, Defaults)}, {K, V})
    end, hornbeam_config:multi_defaults()).
