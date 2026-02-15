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
%%%
%%% Tests ASGI 3.0 specification compliance and various HTTP scenarios.
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

%% Basic tests
-export([
    test_hello_world/1,
    test_not_found/1,
    test_request_info/1,
    test_post_echo/1
]).

%% ASGI compliance tests
-export([
    test_asgi_scope_type/1,
    test_asgi_scope_version/1,
    test_asgi_scope_method/1,
    test_asgi_scope_path/1,
    test_asgi_scope_query_string/1,
    test_asgi_scope_headers/1,
    test_asgi_scope_server/1,
    test_asgi_scope_client/1,
    test_asgi_scope_scheme/1
]).

%% HTTP method tests
-export([
    test_method_get/1,
    test_method_post/1,
    test_method_put/1,
    test_method_delete/1,
    test_method_patch/1,
    test_method_head/1,
    test_method_options/1
]).

%% Status code tests
-export([
    test_status_200/1,
    test_status_201/1,
    test_status_204/1,
    test_status_301/1,
    test_status_302/1,
    test_status_400/1,
    test_status_404/1,
    test_status_500/1
]).

%% Header tests
-export([
    test_custom_headers/1,
    test_multiple_headers/1,
    test_cache_headers/1
]).

%% Body tests
-export([
    test_json_request/1,
    test_large_body/1,
    test_empty_body/1,
    test_unicode_body/1
]).

%% Streaming tests
-export([
    test_streaming_response/1,
    test_streaming_chunks/1
]).

%% Error handling tests
-export([
    test_error_exception/1
]).

all() ->
    [{group, basic},
     {group, asgi_compliance},
     {group, methods},
     {group, status_codes},
     {group, headers},
     {group, body},
     {group, streaming},
     {group, errors}].

groups() ->
    [{basic, [sequence], [
        test_hello_world,
        test_not_found,
        test_request_info,
        test_post_echo
    ]},
    {asgi_compliance, [sequence], [
        test_asgi_scope_type,
        test_asgi_scope_version,
        test_asgi_scope_method,
        test_asgi_scope_path,
        test_asgi_scope_query_string,
        test_asgi_scope_headers,
        test_asgi_scope_server,
        test_asgi_scope_client,
        test_asgi_scope_scheme
    ]},
    {methods, [sequence], [
        test_method_get,
        test_method_post,
        test_method_put,
        test_method_delete,
        test_method_patch,
        test_method_head,
        test_method_options
    ]},
    {status_codes, [sequence], [
        test_status_200,
        test_status_201,
        test_status_204,
        test_status_301,
        test_status_302,
        test_status_400,
        test_status_404,
        test_status_500
    ]},
    {headers, [sequence], [
        test_custom_headers,
        test_multiple_headers,
        test_cache_headers
    ]},
    {body, [sequence], [
        test_json_request,
        test_large_body,
        test_empty_body,
        test_unicode_body
    ]},
    {streaming, [sequence], [
        test_streaming_response,
        test_streaming_chunks
    ]},
    {errors, [sequence], [
        test_error_exception
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    application:stop(hackney),
    application:stop(hornbeam),
    ok.

init_per_group(Group, Config) when Group =:= basic;
                                    Group =:= asgi_compliance;
                                    Group =:= methods;
                                    Group =:= status_codes;
                                    Group =:= headers;
                                    Group =:= body;
                                    Group =:= streaming;
                                    Group =:= errors ->
    %% Find test apps directory
    TestAppsDir = get_test_apps_dir(),
    ct:pal("Using pythonpath: ~s~n", [TestAppsDir]),

    %% Use dynamic port
    Port = 8866 + erlang:phash2(Group, 100),

    %% Start server with test app
    ok = hornbeam:start("asgi_test_app:application", #{
        bind => list_to_binary(io_lib:format("127.0.0.1:~p", [Port])),
        worker_class => asgi,
        pythonpath => [list_to_binary(TestAppsDir)]
    }),
    timer:sleep(500),
    [{port, Port} | Config];
init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, _Config) when Group =:= basic;
                                    Group =:= asgi_compliance;
                                    Group =:= methods;
                                    Group =:= status_codes;
                                    Group =:= headers;
                                    Group =:= body;
                                    Group =:= streaming;
                                    Group =:= errors ->
    hornbeam:stop(),
    timer:sleep(200),
    ok;
end_per_group(_Group, _Config) ->
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
%%% Basic tests
%%% ============================================================================

test_hello_world(Config) ->
    Url = make_url(Config, <<"/">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(<<"Hello from ASGI Test App!\n">>, Body).

test_not_found(Config) ->
    Url = make_url(Config, <<"/nonexistent">>),
    {ok, 404, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(<<"Not Found\n">>, Body).

test_request_info(Config) ->
    Url = make_url(Config, <<"/info?foo=bar&baz=qux">>),
    {ok, 200, Headers, Body} = hackney:request(get, Url, [], <<>>, []),

    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertEqual(<<"application/json">>, ContentType),

    Info = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"GET">>, maps:get(<<"method">>, Info)),
    ?assertEqual(<<"/info">>, maps:get(<<"path">>, Info)),
    ?assertEqual(<<"foo=bar&baz=qux">>, maps:get(<<"query_string">>, Info)),

    %% Check ASGI version is present
    Asgi = maps:get(<<"asgi">>, Info),
    ?assert(maps:is_key(<<"version">>, Asgi)).

test_post_echo(Config) ->
    Url = make_url(Config, <<"/echo">>),
    ReqBody = <<"Hello, ASGI Echo!">>,
    Headers = [{<<"Content-Type">>, <<"text/plain">>}],
    {ok, 200, RespHeaders, RespBody} = hackney:request(post, Url, Headers, ReqBody, []),

    ?assertEqual(ReqBody, RespBody),
    EchoLength = proplists:get_value(<<"x-echo-length">>, RespHeaders),
    ?assertEqual(<<"17">>, EchoLength).

%%% ============================================================================
%%% ASGI compliance tests
%%% ============================================================================

test_asgi_scope_type(Config) ->
    Url = make_url(Config, <<"/scope">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"http">>, maps:get(<<"type">>, Scope)).

test_asgi_scope_version(Config) ->
    Url = make_url(Config, <<"/scope">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),

    %% ASGI 3.0 requires 'asgi' key with 'version' and optionally 'spec_version'
    Asgi = maps:get(<<"asgi">>, Scope),
    ?assert(maps:is_key(<<"version">>, Asgi)),
    Version = maps:get(<<"version">>, Asgi),
    ?assert(is_binary(Version)),
    %% Version should be like "3.0"
    ?assert(binary:match(Version, <<".">>) =/= nomatch).

test_asgi_scope_method(Config) ->
    %% Test various methods
    Url = make_url(Config, <<"/scope">>),

    {ok, 200, _, Body1} = hackney:request(get, Url, [], <<>>, []),
    Scope1 = jsx:decode(Body1, [return_maps]),
    ?assertEqual(<<"GET">>, maps:get(<<"method">>, Scope1)),

    {ok, 200, _, Body2} = hackney:request(post, Url, [], <<>>, []),
    Scope2 = jsx:decode(Body2, [return_maps]),
    ?assertEqual(<<"POST">>, maps:get(<<"method">>, Scope2)).

test_asgi_scope_path(Config) ->
    Url = make_url(Config, <<"/scope">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),
    Path = maps:get(<<"path">>, Scope),
    ?assert(is_binary(Path)),
    ?assertEqual(<<"/scope">>, Path).

test_asgi_scope_query_string(Config) ->
    Url = make_url(Config, <<"/scope?key1=value1&key2=value2">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),
    QueryString = maps:get(<<"query_string">>, Scope),
    ?assert(is_binary(QueryString)),
    ?assert(binary:match(QueryString, <<"key1=value1">>) =/= nomatch).

test_asgi_scope_headers(Config) ->
    Url = make_url(Config, <<"/scope">>),
    ReqHeaders = [
        {<<"X-Custom-Test">>, <<"test-value">>},
        {<<"Accept">>, <<"application/json">>}
    ],
    {ok, 200, _RespHeaders, Body} = hackney:request(get, Url, ReqHeaders, <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),

    %% Headers should be a list of [name, value] pairs
    Headers = maps:get(<<"headers">>, Scope),
    ?assert(is_list(Headers)).

test_asgi_scope_server(Config) ->
    Port = proplists:get_value(port, Config),
    Url = make_url(Config, <<"/scope">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),

    %% Server is a tuple/list [host, port] in ASGI scope
    Server = maps:get(<<"server">>, Scope),
    ?assert(is_list(Server)),
    [Host, ServerPort] = Server,
    ?assertEqual(<<"127.0.0.1">>, Host),
    %% Port may come as integer or binary depending on serialization
    ActualPort = case ServerPort of
        P when is_integer(P) -> P;
        P when is_binary(P) -> binary_to_integer(P)
    end,
    ?assertEqual(Port, ActualPort).

test_asgi_scope_client(Config) ->
    Url = make_url(Config, <<"/scope">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),

    %% Client is a tuple/list [host, port] in ASGI scope
    Client = maps:get(<<"client">>, Scope),
    ?assert(is_list(Client)),
    ?assertEqual(2, length(Client)).

test_asgi_scope_scheme(Config) ->
    Url = make_url(Config, <<"/scope">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    Scope = jsx:decode(Body, [return_maps]),
    Scheme = maps:get(<<"scheme">>, Scope),
    ?assertEqual(<<"http">>, Scheme).

%%% ============================================================================
%%% HTTP method tests
%%% ============================================================================

test_method_get(Config) ->
    Url = make_url(Config, <<"/methods/GET">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assert(binary:match(Body, <<"Method GET OK">>) =/= nomatch).

test_method_post(Config) ->
    Url = make_url(Config, <<"/methods/POST">>),
    {ok, 200, _Headers, Body} = hackney:request(post, Url, [], <<>>, []),
    ?assert(binary:match(Body, <<"Method POST OK">>) =/= nomatch).

test_method_put(Config) ->
    Url = make_url(Config, <<"/methods/PUT">>),
    {ok, 200, _Headers, Body} = hackney:request(put, Url, [], <<>>, []),
    ?assert(binary:match(Body, <<"Method PUT OK">>) =/= nomatch).

test_method_delete(Config) ->
    Url = make_url(Config, <<"/methods/DELETE">>),
    {ok, 200, _Headers, Body} = hackney:request(delete, Url, [], <<>>, []),
    ?assert(binary:match(Body, <<"Method DELETE OK">>) =/= nomatch).

test_method_patch(Config) ->
    Url = make_url(Config, <<"/methods/PATCH">>),
    {ok, 200, _Headers, Body} = hackney:request(patch, Url, [], <<>>, []),
    ?assert(binary:match(Body, <<"Method PATCH OK">>) =/= nomatch).

test_method_head(Config) ->
    Url = make_url(Config, <<"/methods/HEAD">>),
    %% HEAD request returns no body, hackney returns 3-tuple
    {ok, 200, Headers} = hackney:request(head, Url, [], <<>>, []),
    %% Verify headers are present
    ?assert(proplists:get_value(<<"content-type">>, Headers) =/= undefined),
    ?assert(proplists:get_value(<<"content-length">>, Headers) =/= undefined).

test_method_options(Config) ->
    Url = make_url(Config, <<"/methods/OPTIONS">>),
    {ok, 200, Headers, _Body} = hackney:request(options, Url, [], <<>>, []),
    Allow = proplists:get_value(<<"allow">>, Headers),
    ?assert(Allow =/= undefined),
    ?assert(binary:match(Allow, <<"GET">>) =/= nomatch).

%%% ============================================================================
%%% Status code tests
%%% ============================================================================

test_status_200(Config) ->
    Url = make_url(Config, <<"/status?code=200">>),
    {ok, 200, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []).

test_status_201(Config) ->
    Url = make_url(Config, <<"/status?code=201">>),
    {ok, 201, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []).

test_status_204(Config) ->
    Url = make_url(Config, <<"/status?code=204">>),
    {ok, 204, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(<<>>, Body).

test_status_301(Config) ->
    Url = make_url(Config, <<"/status?code=301&location=/redirected">>),
    {ok, 301, Headers, _Body} = hackney:request(get, Url, [], <<>>, [{follow_redirect, false}]),
    Location = proplists:get_value(<<"location">>, Headers),
    ?assertEqual(<<"/redirected">>, Location).

test_status_302(Config) ->
    Url = make_url(Config, <<"/status?code=302&location=/found">>),
    {ok, 302, Headers, _Body} = hackney:request(get, Url, [], <<>>, [{follow_redirect, false}]),
    Location = proplists:get_value(<<"location">>, Headers),
    ?assertEqual(<<"/found">>, Location).

test_status_400(Config) ->
    Url = make_url(Config, <<"/status?code=400">>),
    {ok, 400, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []).

test_status_404(Config) ->
    Url = make_url(Config, <<"/status?code=404">>),
    {ok, 404, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []).

test_status_500(Config) ->
    Url = make_url(Config, <<"/status?code=500">>),
    {ok, 500, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []).

%%% ============================================================================
%%% Header tests
%%% ============================================================================

test_custom_headers(Config) ->
    Url = make_url(Config, <<"/headers?custom=test-value">>),
    {ok, 200, Headers, _Body} = hackney:request(get, Url, [], <<>>, []),
    CustomHeader = proplists:get_value(<<"x-custom-header">>, Headers),
    ?assertEqual(<<"test-value">>, CustomHeader).

test_multiple_headers(Config) ->
    Url = make_url(Config, <<"/headers?multi=yes">>),
    {ok, 200, Headers, _Body} = hackney:request(get, Url, [], <<>>, []),
    MultiHeaders = [V || {K, V} <- Headers, K =:= <<"x-multi">>],
    ?assert(length(MultiHeaders) >= 1).

test_cache_headers(Config) ->
    Url = make_url(Config, <<"/headers?cache=3600">>),
    {ok, 200, Headers, _Body} = hackney:request(get, Url, [], <<>>, []),
    CacheControl = proplists:get_value(<<"cache-control">>, Headers),
    ?assertEqual(<<"max-age=3600">>, CacheControl).

%%% ============================================================================
%%% Body tests
%%% ============================================================================

test_json_request(Config) ->
    Url = make_url(Config, <<"/json">>),
    ReqBody = <<"{\"key\": \"value\", \"number\": 42}">>,
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    {ok, 200, RespHeaders, RespBody} = hackney:request(post, Url, Headers, ReqBody, []),

    ContentType = proplists:get_value(<<"content-type">>, RespHeaders),
    ?assertEqual(<<"application/json">>, ContentType),

    Response = jsx:decode(RespBody, [return_maps]),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Response)),
    Received = maps:get(<<"received">>, Response),
    ?assertEqual(<<"value">>, maps:get(<<"key">>, Received)),
    ?assertEqual(42, maps:get(<<"number">>, Received)).

test_large_body(Config) ->
    Url = make_url(Config, <<"/large?size=102400">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(102400, byte_size(Body)).

test_empty_body(Config) ->
    Url = make_url(Config, <<"/echo">>),
    {ok, 200, _Headers, Body} = hackney:request(post, Url, [], <<>>, []),
    ?assertEqual(<<>>, Body).

test_unicode_body(Config) ->
    Url = make_url(Config, <<"/unicode">>),
    {ok, 200, Headers, Body} = hackney:request(get, Url, [], <<>>, []),

    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assert(binary:match(ContentType, <<"utf-8">>) =/= nomatch),

    ?assert(binary:match(Body, <<"café"/utf8>>) =/= nomatch),
    ?assert(binary:match(Body, <<"中文"/utf8>>) =/= nomatch),
    ?assert(binary:match(Body, <<"🎉"/utf8>>) =/= nomatch).

%%% ============================================================================
%%% Streaming tests
%%% ============================================================================

test_streaming_response(Config) ->
    Url = make_url(Config, <<"/streaming?chunks=3&size=50">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),

    ?assert(binary:match(Body, <<"Chunk 1">>) =/= nomatch),
    ?assert(binary:match(Body, <<"Chunk 2">>) =/= nomatch),
    ?assert(binary:match(Body, <<"Chunk 3">>) =/= nomatch).

test_streaming_chunks(Config) ->
    Url = make_url(Config, <<"/streaming?chunks=5&size=100">>),
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),

    %% Should have 5 chunks
    Matches = binary:matches(Body, <<"Chunk">>),
    ?assertEqual(5, length(Matches)).

%%% ============================================================================
%%% Error handling tests
%%% ============================================================================

test_error_exception(Config) ->
    Url = make_url(Config, <<"/error?type=exception">>),
    {ok, 500, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),
    ?assert(binary:match(Body, <<"Internal Server Error">>) =/= nomatch).
