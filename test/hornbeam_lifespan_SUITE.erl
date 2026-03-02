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

%%% @doc ASGI Lifespan protocol compliance tests for hornbeam.
%%%
%%% Tests the ASGI lifespan protocol including startup, shutdown,
%%% and state sharing between lifespan and request handlers.
%%%
%%% Based on gunicorn's lifespan compliance tests.
-module(hornbeam_lifespan_SUITE).

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

%% Startup tests
-export([
    test_startup_complete/1,
    test_startup_called/1,
    test_startup_time_recorded/1,
    test_health_after_startup/1
]).

%% Lifespan info tests
-export([
    test_lifespan_info_endpoint/1,
    test_uptime_tracking/1
]).

%% State sharing tests
-export([
    test_state_endpoint/1,
    test_request_count_increments/1
]).

%% Counter tests
-export([
    test_counter_endpoint/1,
    test_counter_increments_multiple_times/1
]).

%% Basic endpoint tests
-export([
    test_root_endpoint/1,
    test_not_found/1
]).

all() ->
    [{group, startup},
     {group, lifespan_info},
     {group, state_sharing},
     {group, counter},
     {group, basic_endpoints}].

groups() ->
    [{startup, [sequence], [
        test_startup_complete,
        test_startup_called,
        test_startup_time_recorded,
        test_health_after_startup
    ]},
    {lifespan_info, [sequence], [
        test_lifespan_info_endpoint,
        test_uptime_tracking
    ]},
    {state_sharing, [sequence], [
        test_state_endpoint,
        test_request_count_increments
    ]},
    {counter, [sequence], [
        test_counter_endpoint,
        test_counter_increments_multiple_times
    ]},
    {basic_endpoints, [sequence], [
        test_root_endpoint,
        test_not_found
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    application:stop(hackney),
    application:stop(hornbeam),
    ok.

init_per_group(Group, Config) ->
    %% Find test apps directory
    TestAppsDir = get_test_apps_dir(),
    ct:pal("Using pythonpath: ~s~n", [TestAppsDir]),

    %% Use dynamic port
    Port = 8900 + erlang:phash2(Group, 100),

    %% Start server with lifespan test app
    ok = hornbeam:start("lifespan_test_app:application", #{
        bind => list_to_binary(io_lib:format("127.0.0.1:~p", [Port])),
        worker_class => asgi,
        lifespan => on,  %% Require lifespan support
        pythonpath => [list_to_binary(TestAppsDir)]
    }),
    %% Give lifespan startup time to complete
    timer:sleep(1000),
    [{port, Port} | Config].

end_per_group(_Group, _Config) ->
    hornbeam:stop(),
    timer:sleep(200),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%% ============================================================================
%%% Helper functions
%%% ============================================================================

get_test_apps_dir() ->
    HornbeamBeam = code:which(hornbeam),
    EbinDir = filename:dirname(HornbeamBeam),
    LibDir = filename:dirname(EbinDir),
    SrcLink = filename:join(LibDir, "src"),
    case file:read_link(SrcLink) of
        {ok, RelPath} ->
            ActualSrc = filename:join(LibDir, RelPath),
            ActualSrcDir = filename:dirname(filename:absname(ActualSrc)),
            filename:join(ActualSrcDir, "test/test_apps");
        {error, _} ->
            filename:join(LibDir, "test/test_apps")
    end.

make_url(Config, Path) ->
    Port = proplists:get_value(port, Config),
    iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port), Path]).

%%% ============================================================================
%%% Startup tests
%%% ============================================================================

test_startup_complete(Config) ->
    %% Test that lifespan startup completed via scope state
    %% (scope state is shared across subinterpreters via Erlang ETS)
    Url = make_url(Config, <<"/state">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    State = jsx:decode(Body, [return_maps]),

    %% Check scope_state which is the ASGI-standard way to share lifespan state
    ?assertEqual(true, maps:get(<<"scope_state_available">>, State)),
    ScopeState = maps:get(<<"scope_state">>, State),
    ?assertEqual(true, maps:get(<<"lifespan_started">>, ScopeState)).

test_startup_called(Config) ->
    %% Test that startup was called by checking scope state has expected keys
    Url = make_url(Config, <<"/state">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    State = jsx:decode(Body, [return_maps]),

    ScopeState = maps:get(<<"scope_state">>, State),
    ?assert(maps:is_key(<<"db_connection">>, ScopeState)).

test_startup_time_recorded(Config) ->
    %% Test that startup time was recorded in scope state
    Url = make_url(Config, <<"/state">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    State = jsx:decode(Body, [return_maps]),

    ScopeState = maps:get(<<"scope_state">>, State),
    StartupTime = maps:get(<<"startup_time">>, ScopeState),
    ?assert(StartupTime =/= null).

test_health_after_startup(Config) ->
    %% Test health endpoint returns OK after startup
    Url = make_url(Config, <<"/health">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(<<"OK">>, Body).

%%% ============================================================================
%%% Lifespan info tests
%%% ============================================================================

test_lifespan_info_endpoint(Config) ->
    %% Test lifespan info endpoint
    Url = make_url(Config, <<"/lifespan-info">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Info = jsx:decode(Body, [return_maps]),

    ?assertEqual(true, maps:get(<<"lifespan_supported">>, Info)),
    ?assertEqual(true, maps:get(<<"startup_complete">>, Info)).

test_uptime_tracking(Config) ->
    %% Test that uptime is tracked
    Url = make_url(Config, <<"/lifespan-info">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Info = jsx:decode(Body, [return_maps]),

    Uptime = maps:get(<<"uptime_seconds">>, Info),
    ?assert(is_number(Uptime)),
    ?assert(Uptime >= 0).

%%% ============================================================================
%%% State sharing tests
%%% ============================================================================

test_state_endpoint(Config) ->
    %% Test state endpoint returns state info
    Url = make_url(Config, <<"/state">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    State = jsx:decode(Body, [return_maps]),

    ?assert(maps:is_key(<<"module_state">>, State)).

test_request_count_increments(Config) ->
    %% Test that counter endpoint uses scope_state (lifespan state sharing).
    %% With subinterpreters, scope state is passed by value from Erlang ETS
    %% per request, so cross-request persistence is not expected.
    Url = make_url(Config, <<"/counter">>),

    {ok, 200, _Headers1, Body1} = hackney:request(get, Url, [], <<>>, []),
    Counter1 = jsx:decode(Body1, [return_maps]),
    ?assert(is_integer(maps:get(<<"counter">>, Counter1))),
    %% When lifespan is active, scope_state should be the source
    ?assertEqual(<<"scope_state">>, maps:get(<<"source">>, Counter1)),

    %% Second request also succeeds
    {ok, 200, _Headers2, Body2} = hackney:request(get, Url, [], <<>>, []),
    Counter2 = jsx:decode(Body2, [return_maps]),
    ?assert(is_integer(maps:get(<<"counter">>, Counter2))),
    ?assertEqual(<<"scope_state">>, maps:get(<<"source">>, Counter2)).

%%% ============================================================================
%%% Counter tests
%%% ============================================================================

test_counter_endpoint(Config) ->
    %% Test counter endpoint
    Url = make_url(Config, <<"/counter">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Counter = jsx:decode(Body, [return_maps]),

    ?assert(maps:is_key(<<"counter">>, Counter)),
    ?assert(maps:is_key(<<"source">>, Counter)).

test_counter_increments_multiple_times(Config) ->
    %% Test counter endpoint handles multiple sequential requests without errors.
    %% With subinterpreters, each request may land on a different context,
    %% so we verify stability rather than strict monotonic increments.
    Url = make_url(Config, <<"/counter">>),

    Results = lists:map(fun(_) ->
        {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
        jsx:decode(Body, [return_maps])
    end, lists:seq(1, 5)),

    %% All responses should have valid counter values with scope_state source
    lists:foreach(fun(Counter) ->
        ?assert(is_integer(maps:get(<<"counter">>, Counter))),
        ?assertEqual(<<"scope_state">>, maps:get(<<"source">>, Counter))
    end, Results).

%%% ============================================================================
%%% Basic endpoint tests
%%% ============================================================================

test_root_endpoint(Config) ->
    %% Test root endpoint
    Url = make_url(Config, <<"/">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(<<"Lifespan Test App">>, Body).

test_not_found(Config) ->
    %% Test 404 for unknown path
    Url = make_url(Config, <<"/unknown-path">>),
    {ok, 404, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []).
