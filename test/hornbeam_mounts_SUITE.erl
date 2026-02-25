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

%%% @doc Tests for hornbeam_mounts multi-app mount registry.
-module(hornbeam_mounts_SUITE).

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
    test_register_mounts/1,
    test_lookup_exact_match/1,
    test_lookup_prefix_match/1,
    test_lookup_longest_prefix/1,
    test_lookup_root_mount/1,
    test_lookup_no_match/1,
    test_path_stripping/1,
    test_list_mounts/1,
    test_clear_mounts/1
]).

all() ->
    [{group, mounts}].

groups() ->
    [{mounts, [sequence], [
        test_register_mounts,
        test_lookup_exact_match,
        test_lookup_prefix_match,
        test_lookup_longest_prefix,
        test_lookup_root_mount,
        test_lookup_no_match,
        test_path_stripping,
        test_list_mounts,
        test_clear_mounts
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
    hornbeam_mounts:clear(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    hornbeam_mounts:clear(),
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_register_mounts(_Config) ->
    %% Register multiple mounts
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000},
        #{prefix => <<"/admin">>, app_module => <<"admin">>, app_callable => <<"app">>,
          worker_class => wsgi, workers => 2, timeout => 30000},
        #{prefix => <<"/">>, app_module => <<"frontend">>, app_callable => <<"app">>,
          worker_class => wsgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Verify mounts are registered
    RegisteredMounts = hornbeam_mounts:list(),
    ?assertEqual(3, length(RegisteredMounts)).

test_lookup_exact_match(_Config) ->
    %% Register mount
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Test exact match
    {ok, Mount, PathInfo} = hornbeam_mounts:lookup(<<"/api">>),
    ?assertEqual(<<"/api">>, maps:get(prefix, Mount)),
    ?assertEqual(<<"api">>, maps:get(app_module, Mount)),
    ?assertEqual(<<"/">>, PathInfo).

test_lookup_prefix_match(_Config) ->
    %% Register mount
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Test prefix match with path after
    {ok, Mount, PathInfo} = hornbeam_mounts:lookup(<<"/api/users">>),
    ?assertEqual(<<"/api">>, maps:get(prefix, Mount)),
    ?assertEqual(<<"/users">>, PathInfo).

test_lookup_longest_prefix(_Config) ->
    %% Register mounts with overlapping prefixes
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000},
        #{prefix => <<"/api/v2">>, app_module => <<"api_v2">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000},
        #{prefix => <<"/">>, app_module => <<"frontend">>, app_callable => <<"app">>,
          worker_class => wsgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Should match longest prefix
    {ok, Mount1, PathInfo1} = hornbeam_mounts:lookup(<<"/api/v2/users">>),
    ?assertEqual(<<"/api/v2">>, maps:get(prefix, Mount1)),
    ?assertEqual(<<"api_v2">>, maps:get(app_module, Mount1)),
    ?assertEqual(<<"/users">>, PathInfo1),

    %% Should match /api (not /api/v2)
    {ok, Mount2, PathInfo2} = hornbeam_mounts:lookup(<<"/api/v1/users">>),
    ?assertEqual(<<"/api">>, maps:get(prefix, Mount2)),
    ?assertEqual(<<"api">>, maps:get(app_module, Mount2)),
    ?assertEqual(<<"/v1/users">>, PathInfo2).

test_lookup_root_mount(_Config) ->
    %% Register root mount
    Mounts = [
        #{prefix => <<"/">>, app_module => <<"frontend">>, app_callable => <<"app">>,
          worker_class => wsgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Root mount should match any path
    {ok, Mount1, PathInfo1} = hornbeam_mounts:lookup(<<"/anything">>),
    ?assertEqual(<<"/">>, maps:get(prefix, Mount1)),
    ?assertEqual(<<"/anything">>, PathInfo1),

    {ok, Mount2, PathInfo2} = hornbeam_mounts:lookup(<<"/deep/nested/path">>),
    ?assertEqual(<<"/">>, maps:get(prefix, Mount2)),
    ?assertEqual(<<"/deep/nested/path">>, PathInfo2),

    {ok, Mount3, PathInfo3} = hornbeam_mounts:lookup(<<"/">>),
    ?assertEqual(<<"/">>, maps:get(prefix, Mount3)),
    ?assertEqual(<<"/">>, PathInfo3).

test_lookup_no_match(_Config) ->
    %% Register mount without root
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Should not match paths outside the prefix
    ?assertEqual({error, no_match}, hornbeam_mounts:lookup(<<"/other">>)),
    ?assertEqual({error, no_match}, hornbeam_mounts:lookup(<<"/ap">>)),
    ?assertEqual({error, no_match}, hornbeam_mounts:lookup(<<"/apiv2">>)).

test_path_stripping(_Config) ->
    %% Register mounts
    Mounts = [
        #{prefix => <<"/api/v1">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000},
        #{prefix => <<"/">>, app_module => <<"frontend">>, app_callable => <<"app">>,
          worker_class => wsgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% Test various path stripping scenarios
    {ok, _, PathInfo1} = hornbeam_mounts:lookup(<<"/api/v1">>),
    ?assertEqual(<<"/">>, PathInfo1),

    {ok, _, PathInfo2} = hornbeam_mounts:lookup(<<"/api/v1/">>),
    ?assertEqual(<<"/">>, PathInfo2),

    {ok, _, PathInfo3} = hornbeam_mounts:lookup(<<"/api/v1/users">>),
    ?assertEqual(<<"/users">>, PathInfo3),

    {ok, _, PathInfo4} = hornbeam_mounts:lookup(<<"/api/v1/users/123">>),
    ?assertEqual(<<"/users/123">>, PathInfo4).

test_list_mounts(_Config) ->
    %% Empty initially
    ?assertEqual([], hornbeam_mounts:list()),

    %% Register mounts
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000},
        #{prefix => <<"/">>, app_module => <<"frontend">>, app_callable => <<"app">>,
          worker_class => wsgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),

    %% List should return all mounts, sorted by length descending
    Listed = hornbeam_mounts:list(),
    ?assertEqual(2, length(Listed)),
    %% First should be longer prefix
    [First | _] = Listed,
    ?assertEqual(<<"/api">>, maps:get(prefix, First)).

test_clear_mounts(_Config) ->
    %% Register mounts
    Mounts = [
        #{prefix => <<"/api">>, app_module => <<"api">>, app_callable => <<"app">>,
          worker_class => asgi, workers => 4, timeout => 30000}
    ],
    ok = hornbeam_mounts:register(Mounts),
    ?assertEqual(1, length(hornbeam_mounts:list())),

    %% Clear mounts
    ok = hornbeam_mounts:clear(),
    ?assertEqual([], hornbeam_mounts:list()),
    ?assertEqual({error, no_match}, hornbeam_mounts:lookup(<<"/api">>)).
