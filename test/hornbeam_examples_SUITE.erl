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

%%% @doc Integration tests for hornbeam examples.
%%%
%%% These tests verify that the example applications work correctly.
-module(hornbeam_examples_SUITE).

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
    %% WSGI examples
    test_hello_wsgi_root/1,
    test_hello_wsgi_info/1,
    test_hello_wsgi_echo/1,
    test_hello_wsgi_404/1,
    %% ASGI examples
    test_hello_asgi_root/1,
    test_hello_asgi_info/1,
    test_hello_asgi_echo/1,
    test_hello_asgi_404/1,
    %% Benchmark apps
    test_benchmark_wsgi/1,
    test_benchmark_asgi/1
]).

-define(PORT, 18765).
-define(HOST, "127.0.0.1").

all() ->
    [{group, wsgi_examples}, {group, asgi_examples}, {group, benchmark_apps}].

groups() ->
    [
        {wsgi_examples, [sequence], [
            test_hello_wsgi_root,
            test_hello_wsgi_info,
            test_hello_wsgi_echo,
            test_hello_wsgi_404
        ]},
        {asgi_examples, [sequence], [
            test_hello_asgi_root,
            test_hello_asgi_info,
            test_hello_asgi_echo,
            test_hello_asgi_404
        ]},
        {benchmark_apps, [sequence], [
            test_benchmark_wsgi,
            test_benchmark_asgi
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(inets),
    %% Get project root directory for pythonpath resolution
    ProjectRoot = get_project_root(),
    ct:pal("Project root: ~s~n", [ProjectRoot]),
    [{project_root, ProjectRoot} | Config].

get_project_root() ->
    %% Find the project root from the hornbeam module location
    HornbeamBeam = code:which(hornbeam),
    EbinDir = filename:dirname(HornbeamBeam),
    LibDir = filename:dirname(EbinDir),
    SrcLink = filename:join(LibDir, "src"),
    case file:read_link(SrcLink) of
        {ok, RelPath} ->
            ActualSrc = filename:join(LibDir, RelPath),
            filename:dirname(filename:absname(ActualSrc));
        {error, _} ->
            %% Not a symlink, try to find project root from _build path
            case string:find(LibDir, "_build") of
                nomatch ->
                    LibDir;
                _ ->
                    %% Walk up to find project root (before _build)
                    Parts = filename:split(LibDir),
                    find_before_build(Parts, [])
            end
    end.

find_before_build([], Acc) ->
    filename:join(lists:reverse(Acc));
find_before_build(["_build" | _], Acc) ->
    filename:join(lists:reverse(Acc));
find_before_build([H | T], Acc) ->
    find_before_build(T, [H | Acc]).

end_per_suite(_Config) ->
    application:stop(inets),
    application:stop(hornbeam),
    ok.

init_per_group(wsgi_examples, Config) ->
    ProjectRoot = proplists:get_value(project_root, Config),
    PythonPath = filename:join(ProjectRoot, "examples/hello_wsgi"),
    Bind = list_to_binary(io_lib:format("~s:~p", [?HOST, ?PORT])),
    ok = hornbeam:start("app:application", #{
        bind => Bind,
        worker_class => wsgi,
        pythonpath => [list_to_binary(PythonPath)]
    }),
    timer:sleep(500),
    Config;

init_per_group(asgi_examples, Config) ->
    ProjectRoot = proplists:get_value(project_root, Config),
    PythonPath = filename:join(ProjectRoot, "examples/hello_asgi"),
    Bind = list_to_binary(io_lib:format("~s:~p", [?HOST, ?PORT])),
    ok = hornbeam:start("app:application", #{
        bind => Bind,
        worker_class => asgi,
        pythonpath => [list_to_binary(PythonPath)]
    }),
    timer:sleep(500),
    Config;

init_per_group(benchmark_apps, Config) ->
    Config.

end_per_group(wsgi_examples, _Config) ->
    hornbeam:stop(),
    timer:sleep(200),
    ok;

end_per_group(asgi_examples, _Config) ->
    hornbeam:stop(),
    timer:sleep(200),
    ok;

end_per_group(benchmark_apps, _Config) ->
    ok.

init_per_testcase(test_benchmark_wsgi, Config) ->
    ProjectRoot = proplists:get_value(project_root, Config),
    PythonPath = filename:join(ProjectRoot, "benchmarks"),
    Bind = list_to_binary(io_lib:format("~s:~p", [?HOST, ?PORT])),
    ok = hornbeam:start("simple_app:application", #{
        bind => Bind,
        worker_class => wsgi,
        pythonpath => [list_to_binary(PythonPath)]
    }),
    timer:sleep(500),
    Config;

init_per_testcase(test_benchmark_asgi, Config) ->
    ProjectRoot = proplists:get_value(project_root, Config),
    PythonPath = filename:join(ProjectRoot, "benchmarks"),
    Bind = list_to_binary(io_lib:format("~s:~p", [?HOST, ?PORT])),
    ok = hornbeam:start("simple_asgi_app:application", #{
        bind => Bind,
        worker_class => asgi,
        pythonpath => [list_to_binary(PythonPath)]
    }),
    timer:sleep(500),
    Config;

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(test_benchmark_wsgi, _Config) ->
    hornbeam:stop(),
    timer:sleep(200),
    ok;

end_per_testcase(test_benchmark_asgi, _Config) ->
    hornbeam:stop(),
    timer:sleep(200),
    ok;

end_per_testcase(_TestCase, _Config) ->
    ok.

%%% ============================================================================
%%% WSGI Example Tests
%%% ============================================================================

test_hello_wsgi_root(_Config) ->
    Url = url("/"),
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assert(string:find(Body, "Hello from Hornbeam WSGI") =/= nomatch).

test_hello_wsgi_info(_Config) ->
    Url = url("/info"),
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assert(string:find(Body, "Request Info") =/= nomatch),
    ?assert(string:find(Body, "Method: GET") =/= nomatch),
    ?assert(string:find(Body, "Path: /info") =/= nomatch).

test_hello_wsgi_echo(_Config) ->
    Url = url("/echo"),
    TestBody = "Hello Echo Test",
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(
        post,
        {Url, [], "text/plain", TestBody},
        [],
        []
    ),
    ?assertEqual(TestBody, Body).

test_hello_wsgi_404(_Config) ->
    Url = url("/nonexistent"),
    {ok, {{_, 404, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assert(string:find(Body, "Not Found") =/= nomatch).

%%% ============================================================================
%%% ASGI Example Tests
%%% ============================================================================

test_hello_asgi_root(_Config) ->
    Url = url("/"),
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assert(string:find(Body, "Hello from Hornbeam ASGI") =/= nomatch).

test_hello_asgi_info(_Config) ->
    Url = url("/info"),
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assert(string:find(Body, "Request Info") =/= nomatch),
    ?assert(string:find(Body, "Method: GET") =/= nomatch),
    ?assert(string:find(Body, "Path: /info") =/= nomatch),
    ?assert(string:find(Body, "ASGI Version") =/= nomatch).

test_hello_asgi_echo(_Config) ->
    Url = url("/echo"),
    TestBody = "Hello ASGI Echo Test",
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(
        post,
        {Url, [], "text/plain", TestBody},
        [],
        []
    ),
    ?assertEqual(TestBody, Body).

test_hello_asgi_404(_Config) ->
    Url = url("/nonexistent"),
    {ok, {{_, 404, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assert(string:find(Body, "Not Found") =/= nomatch).

%%% ============================================================================
%%% Benchmark App Tests
%%% ============================================================================

test_benchmark_wsgi(_Config) ->
    %% Test root endpoint
    Url = url("/"),
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assertEqual("Hello, World!", Body),

    %% Test large endpoint
    UrlLarge = url("/large"),
    {ok, {{_, 200, _}, Headers, LargeBody}} = httpc:request(get, {UrlLarge, []}, [], []),
    ?assertEqual(65536, length(LargeBody)),

    %% Verify content-length header
    ContentLength = proplists:get_value("content-length", Headers),
    ?assertEqual("65536", ContentLength).

test_benchmark_asgi(_Config) ->
    %% Test root endpoint
    Url = url("/"),
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    ?assertEqual("Hello, World!", Body),

    %% Test large endpoint
    UrlLarge = url("/large"),
    {ok, {{_, 200, _}, Headers, LargeBody}} = httpc:request(get, {UrlLarge, []}, [], []),
    ?assertEqual(65536, length(LargeBody)),

    %% Verify content-length header
    ContentLength = proplists:get_value("content-length", Headers),
    ?assertEqual("65536", ContentLength).

%%% ============================================================================
%%% Helper functions
%%% ============================================================================

url(Path) ->
    lists:flatten(io_lib:format("http://~s:~p~s", [?HOST, ?PORT, Path])).
