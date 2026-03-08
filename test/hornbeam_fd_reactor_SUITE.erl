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

%%% @doc Integration tests for FD reactor mode.
-module(hornbeam_fd_reactor_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    simple_get_test/1,
    post_with_body_test/1,
    multiple_headers_test/1,
    keep_alive_test/1,
    error_handling_test/1
]).

-define(PORT, 18080).
-define(HOST, "127.0.0.1").

all() ->
    [
        simple_get_test,
        post_with_body_test,
        multiple_headers_test,
        keep_alive_test,
        error_handling_test
    ].

groups() ->
    [].

init_per_suite(Config) ->
    %% Start required applications
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    application:stop(hackney),
    application:stop(hornbeam),
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Create test WSGI app
    PrivDir = code:priv_dir(hornbeam),
    TestApp = filename:join(PrivDir, "test_wsgi_app.py"),
    ok = file:write_file(TestApp, test_wsgi_app_code()),
    [{test_app, TestApp} | Config].

end_per_testcase(_TestCase, Config) ->
    %% Stop hornbeam if running
    catch hornbeam:stop(),
    %% Clean up test app
    TestApp = proplists:get_value(test_app, Config),
    catch file:delete(TestApp),
    ok.

%%% ============================================================================
%%% Test Cases
%%% ============================================================================

simple_get_test(Config) ->
    %% Start hornbeam with fd_reactor mode
    ok = start_hornbeam_fd_reactor(Config),

    %% Make request
    Url = "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/",
    {ok, StatusCode, _Headers, Body} = hackney:request(get, Url, [], <<>>, []),

    ?assertEqual(200, StatusCode),
    ?assertEqual(<<"Hello World">>, Body),

    hornbeam:stop(),
    ok.

post_with_body_test(Config) ->
    ok = start_hornbeam_fd_reactor(Config),

    Url = "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/echo",
    ReqBody = <<"test body data">>,
    Headers = [{<<"content-type">>, <<"text/plain">>}],

    {ok, StatusCode, _RespHeaders, RespBody} = hackney:request(post, Url, Headers, ReqBody, []),

    ?assertEqual(200, StatusCode),
    ?assertEqual(ReqBody, RespBody),

    hornbeam:stop(),
    ok.

multiple_headers_test(Config) ->
    ok = start_hornbeam_fd_reactor(Config),

    Url = "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/headers",
    Headers = [
        {<<"x-custom-1">>, <<"value1">>},
        {<<"x-custom-2">>, <<"value2">>},
        {<<"accept">>, <<"application/json">>}
    ],

    {ok, StatusCode, _RespHeaders, Body} = hackney:request(get, Url, Headers, <<>>, []),

    ?assertEqual(200, StatusCode),
    %% Body should contain the headers (WSGI format: HTTP_X_CUSTOM_1)
    ?assert(binary:match(Body, <<"HTTP_X_CUSTOM_1">>) =/= nomatch),

    hornbeam:stop(),
    ok.

keep_alive_test(Config) ->
    ok = start_hornbeam_fd_reactor(Config),

    %% Make multiple requests on same connection
    Url = "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/",

    %% First request
    {ok, Status1, _, _Body1} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(200, Status1),

    %% Second request (should reuse connection with keep-alive)
    {ok, Status2, _, _Body2} = hackney:request(get, Url, [], <<>>, []),
    ?assertEqual(200, Status2),

    hornbeam:stop(),
    ok.

error_handling_test(Config) ->
    ok = start_hornbeam_fd_reactor(Config),

    %% Request non-existent path
    Url = "http://" ++ ?HOST ++ ":" ++ integer_to_list(?PORT) ++ "/not-found",
    {ok, StatusCode, _Headers, _Body} = hackney:request(get, Url, [], <<>>, []),

    ?assertEqual(404, StatusCode),

    hornbeam:stop(),
    ok.

%%% ============================================================================
%%% Helpers
%%% ============================================================================

start_hornbeam_fd_reactor(_Config) ->
    %% Start with fd_reactor backend mode
    hornbeam:start("test_wsgi_app:app", #{
        bind => ?HOST ++ ":" ++ integer_to_list(?PORT),
        backend_mode => fd_reactor,
        workers => 2,
        timeout => 30000
    }).

test_wsgi_app_code() ->
    <<"
def app(environ, start_response):
    path = environ.get('PATH_INFO', '/')

    if path == '/':
        start_response('200 OK', [('Content-Type', 'text/plain')])
        return [b'Hello World']

    elif path == '/echo':
        body = environ['wsgi.input'].read()
        start_response('200 OK', [
            ('Content-Type', environ.get('CONTENT_TYPE', 'text/plain')),
            ('Content-Length', str(len(body)))
        ])
        return [body]

    elif path == '/headers':
        headers_str = '\\n'.join(
            f'{k}: {v}' for k, v in environ.items()
            if k.startswith('HTTP_')
        )
        body = headers_str.encode('utf-8')
        start_response('200 OK', [
            ('Content-Type', 'text/plain'),
            ('Content-Length', str(len(body)))
        ])
        return [body]

    else:
        start_response('404 Not Found', [('Content-Type', 'text/plain')])
        return [b'Not Found']
">>.
