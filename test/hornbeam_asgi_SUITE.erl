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

%%% @doc ASGI protocol tests for hornbeam.
-module(hornbeam_asgi_SUITE).

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
    test_hello_world/1,
    test_not_found/1,
    test_request_info/1,
    test_post_echo/1
]).

all() ->
    [{group, asgi}].

groups() ->
    [{asgi, [sequence], [
        test_hello_world,
        test_not_found,
        test_request_info,
        test_post_echo
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    application:stop(hackney),
    application:stop(hornbeam),
    ok.

init_per_group(asgi, Config) ->
    %% Find hornbeam source directory from module path
    HornbeamBeam = code:which(hornbeam),
    EbinDir = filename:dirname(HornbeamBeam),
    LibDir = filename:dirname(EbinDir),
    SrcLink = filename:join(LibDir, "src"),
    case file:read_link(SrcLink) of
        {ok, RelPath} ->
            ActualSrc = filename:join(LibDir, RelPath),
            ActualSrcDir = filename:dirname(filename:absname(ActualSrc)),
            ExamplesDir = filename:join(ActualSrcDir, "examples/hello_asgi");
        {error, _} ->
            ExamplesDir = filename:join(LibDir, "examples/hello_asgi")
    end,

    ct:pal("Using pythonpath: ~s~n", [ExamplesDir]),

    %% Start server with hello_asgi app
    ok = hornbeam:start("app:application", #{
        bind => <<"127.0.0.1:8766">>,
        worker_class => asgi,
        pythonpath => [list_to_binary(ExamplesDir)]
    }),
    timer:sleep(1000),  % Give server time to start
    [{port, 8766} | Config];
init_per_group(_Group, Config) ->
    Config.

end_per_group(asgi, _Config) ->
    hornbeam:stop(),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_hello_world(Config) ->
    Port = proplists:get_value(port, Config),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/">>,

    %% hackney 3.0 returns body directly in response tuple
    case hackney:request(get, Url, [], <<>>, []) of
        {ok, 200, _Headers, Body} ->
            ?assertEqual(<<"Hello from Hornbeam ASGI!\n">>, Body);
        {ok, Status, _Headers, Body} ->
            ct:pal("Got status ~p with body: ~p~n", [Status, Body]),
            ?assertEqual(200, Status);
        {error, Reason} ->
            ct:fail("HTTP request failed: ~p", [Reason])
    end.

test_not_found(Config) ->
    Port = proplists:get_value(port, Config),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/nonexistent">>,

    {ok, 404, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(<<"Not Found\n">>, Body).

test_request_info(Config) ->
    Port = proplists:get_value(port, Config),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/info?foo=bar">>,

    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),

    %% Check body contains expected info
    ?assert(binary:match(Body, <<"Method: GET">>) =/= nomatch),
    ?assert(binary:match(Body, <<"Path: /info">>) =/= nomatch),
    ?assert(binary:match(Body, <<"ASGI Version:">>) =/= nomatch).

test_post_echo(Config) ->
    Port = proplists:get_value(port, Config),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/echo">>,

    ReqBody = <<"Hello, ASGI Echo!">>,
    Headers = [{<<"Content-Type">>, <<"text/plain">>}],
    {ok, 200, _RespHeaders, RespBody} = hackney:request(post, Url, Headers, ReqBody, []),

    ?assertEqual(ReqBody, RespBody).
