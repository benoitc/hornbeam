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

%%% @doc Integration tests for hornbeam multi-app mount support.
-module(hornbeam_multiapp_SUITE).

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
    test_multi_app_start/1,
    test_routing_to_api_mount/1,
    test_routing_to_admin_mount/1,
    test_routing_to_root_mount/1,
    test_longest_prefix_matching/1,
    test_script_name_path_info/1,
    test_no_match_returns_404/1,
    test_backward_compat_single_app/1,
    test_validation_invalid_prefix/1,
    test_validation_duplicate_prefix/1
]).

all() ->
    [{group, multiapp}, {group, validation}].

groups() ->
    [{multiapp, [sequence], [
        test_multi_app_start,
        test_routing_to_api_mount,
        test_routing_to_admin_mount,
        test_routing_to_root_mount,
        test_longest_prefix_matching,
        test_script_name_path_info,
        test_no_match_returns_404,
        test_backward_compat_single_app
    ]},
    {validation, [sequence], [
        test_validation_invalid_prefix,
        test_validation_duplicate_prefix
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    application:stop(hackney),
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
    hornbeam_mounts:clear(),
    timer:sleep(100),  %% Give the listener time to stop
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_multi_app_start(_Config) ->
    %% Start with multi-app config
    ExamplesDir = get_examples_dir(),
    ok = hornbeam:start(#{
        mounts => [
            {"/api", "multi_app_test.api_app:application", #{worker_class => wsgi}},
            {"/admin", "multi_app_test.admin_app:application", #{worker_class => wsgi}},
            {"/", "multi_app_test.frontend_app:application", #{worker_class => wsgi}}
        ],
        bind => <<"127.0.0.1:18080">>,
        pythonpath => [ExamplesDir]
    }),

    %% Verify listener is running
    Listeners = ranch:info(),
    ?assert(lists:keymember(hornbeam_http, 1, Listeners)),

    %% Verify mounts are registered
    Mounts = hornbeam_mounts:list(),
    ?assertEqual(3, length(Mounts)).

test_routing_to_api_mount(_Config) ->
    %% Start multi-app server
    ok = start_multi_app_server(),

    %% Request to /api should route to api_app
    {ok, 200, _Headers, Body} = hackney:request(get, "http://127.0.0.1:18080/api", [], <<>>, []),

    %% Parse JSON response
    Response = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"api">>, maps:get(<<"app">>, Response)),
    ?assertEqual(<<"/">>, maps:get(<<"path_info">>, Response)),
    ?assertEqual(<<"/api">>, maps:get(<<"script_name">>, Response)).

test_routing_to_admin_mount(_Config) ->
    %% Start multi-app server
    ok = start_multi_app_server(),

    %% Request to /admin/users should route to admin_app
    {ok, 200, _Headers, Body} = hackney:request(get, "http://127.0.0.1:18080/admin/users", [], <<>>, []),

    %% Parse JSON response
    Response = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"admin">>, maps:get(<<"app">>, Response)),
    ?assertEqual(<<"/users">>, maps:get(<<"path_info">>, Response)),
    ?assertEqual(<<"/admin">>, maps:get(<<"script_name">>, Response)).

test_routing_to_root_mount(_Config) ->
    %% Start multi-app server
    ok = start_multi_app_server(),

    %% Request to /other should route to frontend_app (root mount)
    {ok, 200, _Headers, Body} = hackney:request(get, "http://127.0.0.1:18080/other/page", [], <<>>, []),

    %% Parse JSON response
    Response = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"frontend">>, maps:get(<<"app">>, Response)),
    ?assertEqual(<<"/other/page">>, maps:get(<<"path_info">>, Response)),
    ?assertEqual(<<"/">>, maps:get(<<"script_name">>, Response)).

test_longest_prefix_matching(_Config) ->
    %% Start with overlapping prefixes
    ExamplesDir = get_examples_dir(),
    ok = hornbeam:start(#{
        mounts => [
            {"/api/v2", "multi_app_test.admin_app:application", #{worker_class => wsgi}},
            {"/api", "multi_app_test.api_app:application", #{worker_class => wsgi}},
            {"/", "multi_app_test.frontend_app:application", #{worker_class => wsgi}}
        ],
        bind => <<"127.0.0.1:18080">>,
        pythonpath => [ExamplesDir]
    }),

    %% /api/v2/users should match /api/v2 (longer prefix), not /api
    {ok, 200, _Headers1, Body1} = hackney:request(get, "http://127.0.0.1:18080/api/v2/users", [], <<>>, []),
    Response1 = jsx:decode(Body1, [return_maps]),
    ?assertEqual(<<"admin">>, maps:get(<<"app">>, Response1)),
    ?assertEqual(<<"/users">>, maps:get(<<"path_info">>, Response1)),
    ?assertEqual(<<"/api/v2">>, maps:get(<<"script_name">>, Response1)),

    %% /api/v1/users should match /api
    {ok, 200, _Headers2, Body2} = hackney:request(get, "http://127.0.0.1:18080/api/v1/users", [], <<>>, []),
    Response2 = jsx:decode(Body2, [return_maps]),
    ?assertEqual(<<"api">>, maps:get(<<"app">>, Response2)),
    ?assertEqual(<<"/v1/users">>, maps:get(<<"path_info">>, Response2)),
    ?assertEqual(<<"/api">>, maps:get(<<"script_name">>, Response2)).

test_script_name_path_info(_Config) ->
    %% Start multi-app server
    ok = start_multi_app_server(),

    %% Test various paths
    TestCases = [
        {"/api", <<"/api">>, <<"/">>},
        {"/api/", <<"/api">>, <<"/">>},
        {"/api/users", <<"/api">>, <<"/users">>},
        {"/api/users/123", <<"/api">>, <<"/users/123">>}
    ],

    lists:foreach(fun({Path, ExpectedScript, ExpectedPath}) ->
        Url = "http://127.0.0.1:18080" ++ Path,
        {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
        Response = jsx:decode(Body, [return_maps]),
        ?assertEqual(ExpectedScript, maps:get(<<"script_name">>, Response),
                     {path, Path, expected_script, ExpectedScript}),
        ?assertEqual(ExpectedPath, maps:get(<<"path_info">>, Response),
                     {path, Path, expected_path, ExpectedPath})
    end, TestCases).

test_no_match_returns_404(_Config) ->
    %% Start server without root mount
    ExamplesDir = get_examples_dir(),
    ok = hornbeam:start(#{
        mounts => [
            {"/api", "multi_app_test.api_app:application", #{worker_class => wsgi}}
        ],
        bind => <<"127.0.0.1:18080">>,
        pythonpath => [ExamplesDir]
    }),

    %% Request to unmatched path should return 404
    {ok, 404, _Headers, _Body} = hackney:request(get, "http://127.0.0.1:18080/other", [], <<>>, []).

test_backward_compat_single_app(_Config) ->
    %% Test that single-app mode still works
    ok = hornbeam:start("hello_wsgi.app:application", #{
        bind => <<"127.0.0.1:18080">>
    }),

    %% Should work as before
    {ok, 200, _Headers, Body} = hackney:request(get, "http://127.0.0.1:18080/", [], <<>>, []),
    ?assertEqual(<<"Hello from Hornbeam WSGI!\n">>, Body).

test_validation_invalid_prefix(_Config) ->
    %% Prefix must start with /
    Result1 = hornbeam:start(#{
        mounts => [
            {"api", "multi_app_test.api_app:application", #{worker_class => wsgi}}
        ]
    }),
    ?assertMatch({error, {invalid_mount, {prefix_must_start_with_slash, _}}}, Result1),

    %% Prefix must not end with / (except root)
    Result2 = hornbeam:start(#{
        mounts => [
            {"/api/", "multi_app_test.api_app:application", #{worker_class => wsgi}}
        ]
    }),
    ?assertMatch({error, {invalid_mount, {prefix_must_not_end_with_slash, _}}}, Result2).

test_validation_duplicate_prefix(_Config) ->
    %% Duplicate prefixes should fail
    Result = hornbeam:start(#{
        mounts => [
            {"/api", "multi_app_test.api_app:application", #{worker_class => wsgi}},
            {"/api", "multi_app_test.admin_app:application", #{worker_class => wsgi}}
        ]
    }),
    ?assertEqual({error, duplicate_mount_prefix}, Result).

%%% ============================================================================
%%% Helper functions
%%% ============================================================================

start_multi_app_server() ->
    %% Get absolute path to examples directory
    ExamplesDir = get_examples_dir(),
    Result = hornbeam:start(#{
        mounts => [
            {"/api", "multi_app_test.api_app:application", #{worker_class => wsgi}},
            {"/admin", "multi_app_test.admin_app:application", #{worker_class => wsgi}},
            {"/", "multi_app_test.frontend_app:application", #{worker_class => wsgi}}
        ],
        bind => <<"127.0.0.1:18080">>,
        pythonpath => [ExamplesDir]
    }),
    timer:sleep(200),  %% Wait for server to be fully ready
    Result.

get_examples_dir() ->
    %% Get the project root by finding the priv directory
    %% which has a symlink to the real project in CT environment
    case code:priv_dir(hornbeam) of
        {error, _} ->
            %% Fallback: try to find it via code:lib_dir
            case code:lib_dir(hornbeam) of
                {error, _} ->
                    <<"examples">>;
                LibDir ->
                    %% In _build/test/lib/hornbeam -> go up to find project root
                    %% _build/test/lib/hornbeam -> project root (4 levels up)
                    ProjectDir = filename:dirname(filename:dirname(filename:dirname(filename:dirname(LibDir)))),
                    list_to_binary(filename:join(ProjectDir, "examples"))
            end;
        PrivDir ->
            %% priv/ is symlinked to real project's priv
            %% So PrivDir is /path/to/project/priv or _build/test/lib/hornbeam/priv
            RealPrivDir = case file:read_link(PrivDir) of
                {ok, Target} ->
                    %% Follow symlink
                    case filename:pathtype(Target) of
                        absolute -> Target;
                        relative -> filename:join(filename:dirname(PrivDir), Target)
                    end;
                {error, _} ->
                    PrivDir
            end,
            ProjectDir = filename:dirname(RealPrivDir),
            list_to_binary(filename:join(ProjectDir, "examples"))
    end.
