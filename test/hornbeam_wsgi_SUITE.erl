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

%%% @doc WSGI protocol tests for hornbeam.
%%%
%%% Tests WSGI specification compliance and various HTTP scenarios.
-module(hornbeam_wsgi_SUITE).

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
    test_streaming_response/1
]).

%% Error handling tests
-export([
    test_error_exception/1
]).

all() ->
    [{group, basic},
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
        test_streaming_response
    ]},
    {errors, [sequence], [
        test_error_exception
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(livery),
    Config.

end_per_suite(_Config) ->
    ok,
    application:stop(hornbeam),
    ok.

init_per_group(Group, Config) when Group =:= basic;
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
    Port = 8765 + erlang:phash2(Group, 100),

    %% Start server with test app
    ok = hornbeam:start("wsgi_test_app:application", #{
        bind => list_to_binary(io_lib:format("127.0.0.1:~p", [Port])),
        pythonpath => [list_to_binary(TestAppsDir)]
    }),
    timer:sleep(500),
    [{port, Port} | Config];
init_per_group(_Group, Config) ->
    Config.

end_per_group(Group, _Config) when Group =:= basic;
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
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),
    ?assertEqual(<<"Hello from WSGI Test App!\n">>, Body).

test_not_found(Config) ->
    Url = make_url(Config, <<"/nonexistent">>),
    {ok, #{status := 404, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),
    ?assertEqual(<<"Not Found\n">>, Body).

test_request_info(Config) ->
    Url = make_url(Config, <<"/info?foo=bar&baz=qux">>),
    {ok, #{status := 200, body := {full, Body}} = Resp} = hornbeam_test_http:request(get, Url, #{}),

    %% Should be JSON
    ContentType = livery_client:header(<<"content-type">>, Resp),
    ?assertEqual(<<"application/json">>, ContentType),

    %% Parse JSON and check fields
    Info = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"GET">>, maps:get(<<"method">>, Info)),
    ?assertEqual(<<"/info">>, maps:get(<<"path">>, Info)),
    ?assertEqual(<<"foo=bar&baz=qux">>, maps:get(<<"query_string">>, Info)).

test_post_echo(Config) ->
    Url = make_url(Config, <<"/echo">>),
    ReqBody = <<"Hello, Echo!">>,
    Headers = [{<<"Content-Type">>, <<"text/plain">>}],
    {ok, #{status := 200, body := {full, RespBody}} = Resp} = hornbeam_test_http:request(post, Url, #{headers => Headers, body => ReqBody}),

    ?assertEqual(ReqBody, RespBody),
    %% Check echo length header
    EchoLength = livery_client:header(<<"x-echo-length">>, Resp),
    ?assertEqual(<<"12">>, EchoLength).

%%% ============================================================================
%%% HTTP method tests
%%% ============================================================================

test_method_get(Config) ->
    Url = make_url(Config, <<"/methods/GET">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),
    ?assert(binary:match(Body, <<"Method GET OK">>) =/= nomatch).

test_method_post(Config) ->
    Url = make_url(Config, <<"/methods/POST">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(post, Url, #{}),
    ?assert(binary:match(Body, <<"Method POST OK">>) =/= nomatch).

test_method_put(Config) ->
    Url = make_url(Config, <<"/methods/PUT">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(put, Url, #{}),
    ?assert(binary:match(Body, <<"Method PUT OK">>) =/= nomatch).

test_method_delete(Config) ->
    Url = make_url(Config, <<"/methods/DELETE">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(delete, Url, #{}),
    ?assert(binary:match(Body, <<"Method DELETE OK">>) =/= nomatch).

test_method_patch(Config) ->
    Url = make_url(Config, <<"/methods/PATCH">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(patch, Url, #{}),
    ?assert(binary:match(Body, <<"Method PATCH OK">>) =/= nomatch).

test_method_head(Config) ->
    Url = make_url(Config, <<"/methods/HEAD">>),
    %% HEAD request returns no body, client returns 3-tuple
    {ok, #{status := 200} = Resp} = hornbeam_test_http:request(head, Url, #{}),
    %% Verify headers are present
    ?assert(livery_client:header(<<"content-type">>, Resp) =/= undefined),
    ?assert(livery_client:header(<<"content-length">>, Resp) =/= undefined).

test_method_options(Config) ->
    Url = make_url(Config, <<"/methods/OPTIONS">>),
    {ok, #{status := 200} = Resp} = hornbeam_test_http:request(options, Url, #{}),
    Allow = livery_client:header(<<"allow">>, Resp),
    ?assert(Allow =/= undefined),
    ?assert(binary:match(Allow, <<"GET">>) =/= nomatch).

%%% ============================================================================
%%% Status code tests
%%% ============================================================================

test_status_200(Config) ->
    Url = make_url(Config, <<"/status?code=200">>),
    {ok, #{status := 200}} = hornbeam_test_http:request(get, Url, #{}).

test_status_201(Config) ->
    Url = make_url(Config, <<"/status?code=201">>),
    {ok, #{status := 201}} = hornbeam_test_http:request(get, Url, #{}).

test_status_204(Config) ->
    Url = make_url(Config, <<"/status?code=204">>),
    {ok, #{status := 204, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),
    ?assertEqual(<<>>, Body).

test_status_301(Config) ->
    Url = make_url(Config, <<"/status?code=301&location=/redirected">>),
    %% Don't follow redirects
    {ok, #{status := 301} = Resp} = hornbeam_test_http:request(get, Url, #{}),
    Location = livery_client:header(<<"location">>, Resp),
    ?assertEqual(<<"/redirected">>, Location).

test_status_302(Config) ->
    Url = make_url(Config, <<"/status?code=302&location=/found">>),
    {ok, #{status := 302} = Resp} = hornbeam_test_http:request(get, Url, #{}),
    Location = livery_client:header(<<"location">>, Resp),
    ?assertEqual(<<"/found">>, Location).

test_status_400(Config) ->
    Url = make_url(Config, <<"/status?code=400">>),
    {ok, #{status := 400}} = hornbeam_test_http:request(get, Url, #{}).

test_status_404(Config) ->
    Url = make_url(Config, <<"/status?code=404">>),
    {ok, #{status := 404}} = hornbeam_test_http:request(get, Url, #{}).

test_status_500(Config) ->
    Url = make_url(Config, <<"/status?code=500">>),
    {ok, #{status := 500}} = hornbeam_test_http:request(get, Url, #{}).

%%% ============================================================================
%%% Header tests
%%% ============================================================================

test_custom_headers(Config) ->
    Url = make_url(Config, <<"/headers?custom=test-value">>),
    {ok, #{status := 200} = Resp} = hornbeam_test_http:request(get, Url, #{}),
    CustomHeader = livery_client:header(<<"x-custom-header">>, Resp),
    ?assertEqual(<<"test-value">>, CustomHeader).

test_multiple_headers(Config) ->
    Url = make_url(Config, <<"/headers?multi=yes">>),
    {ok, #{status := 200} = Resp} = hornbeam_test_http:request(get, Url, #{}),
    %% Multiple headers with same name should be present
    MultiHeaders = [V || {K, V} <- livery_client:headers(Resp), string:lowercase(K) =:= <<"x-multi">>],
    ?assert(length(MultiHeaders) >= 1).

test_cache_headers(Config) ->
    Url = make_url(Config, <<"/headers?cache=3600">>),
    {ok, #{status := 200} = Resp} = hornbeam_test_http:request(get, Url, #{}),
    CacheControl = livery_client:header(<<"cache-control">>, Resp),
    ?assertEqual(<<"max-age=3600">>, CacheControl).

%%% ============================================================================
%%% Body tests
%%% ============================================================================

test_json_request(Config) ->
    Url = make_url(Config, <<"/json">>),
    ReqBody = <<"{\"key\": \"value\", \"number\": 42}">>,
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    {ok, #{status := 200, body := {full, RespBody}} = Resp} = hornbeam_test_http:request(post, Url, #{headers => Headers, body => ReqBody}),

    ContentType = livery_client:header(<<"content-type">>, Resp),
    ?assertEqual(<<"application/json">>, ContentType),

    Response = jsx:decode(RespBody, [return_maps]),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Response)),
    Received = maps:get(<<"received">>, Response),
    ?assertEqual(<<"value">>, maps:get(<<"key">>, Received)),
    ?assertEqual(42, maps:get(<<"number">>, Received)).

test_large_body(Config) ->
    Url = make_url(Config, <<"/large?size=102400">>),  % 100KB
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),
    ?assertEqual(102400, byte_size(Body)).

test_empty_body(Config) ->
    Url = make_url(Config, <<"/echo">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(post, Url, #{}),
    ?assertEqual(<<>>, Body).

test_unicode_body(Config) ->
    Url = make_url(Config, <<"/unicode">>),
    {ok, #{status := 200, body := {full, Body}} = Resp} = hornbeam_test_http:request(get, Url, #{}),

    ContentType = livery_client:header(<<"content-type">>, Resp),
    ?assert(binary:match(ContentType, <<"utf-8">>) =/= nomatch),

    %% Check various unicode characters are present
    ?assert(binary:match(Body, <<"café"/utf8>>) =/= nomatch),
    ?assert(binary:match(Body, <<"中文"/utf8>>) =/= nomatch),
    ?assert(binary:match(Body, <<"🎉"/utf8>>) =/= nomatch).

%%% ============================================================================
%%% Streaming tests
%%% ============================================================================

test_streaming_response(Config) ->
    Url = make_url(Config, <<"/streaming?chunks=3&size=50">>),
    {ok, #{status := 200, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),

    %% Should have 3 chunks
    ?assert(binary:match(Body, <<"Chunk 1">>) =/= nomatch),
    ?assert(binary:match(Body, <<"Chunk 2">>) =/= nomatch),
    ?assert(binary:match(Body, <<"Chunk 3">>) =/= nomatch).

%%% ============================================================================
%%% Error handling tests
%%% ============================================================================

test_error_exception(Config) ->
    Url = make_url(Config, <<"/error?type=exception">>),
    {ok, #{status := 500, body := {full, Body}}} = hornbeam_test_http:request(get, Url, #{}),
    ?assert(binary:match(Body, <<"Internal Server Error">>) =/= nomatch).
