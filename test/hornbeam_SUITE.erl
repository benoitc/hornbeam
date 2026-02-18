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
    test_config_venv/1,
    test_register_function/1,
    test_ssl_config/1,
    test_ssl_missing_certfile/1,
    test_websocket_compress_config/1,
    test_hooks_on_request/1,
    test_hooks_on_response/1,
    test_hooks_on_error/1,
    test_hooks_exception_handling/1,
    test_ipv6_parse/1
]).

all() ->
    [{group, basic}].

groups() ->
    [{basic, [sequence], [
        test_start_stop,
        test_config,
        test_config_venv,
        test_register_function,
        test_ssl_config,
        test_ssl_missing_certfile,
        test_websocket_compress_config,
        test_hooks_on_request,
        test_hooks_on_response,
        test_hooks_on_error,
        test_hooks_exception_handling,
        test_ipv6_parse
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

test_config_venv(_Config) ->
    %% Test that venv option is recognized in defaults
    Defaults = hornbeam_config:defaults(),
    ?assert(maps:is_key(venv, Defaults)),
    ?assertEqual(undefined, maps:get(venv, Defaults)),

    %% Test that venv option can be set
    hornbeam_config:set_config(#{venv => <<"/path/to/venv">>}),
    ?assertEqual(<<"/path/to/venv">>, hornbeam_config:get_config(venv)),

    %% Test that venv is merged with defaults
    hornbeam_config:set_config(#{venv => <<"/another/venv">>}),
    Config = hornbeam_config:get_config(),
    ?assertEqual(<<"/another/venv">>, maps:get(venv, Config)),
    %% Verify defaults are still present
    ?assert(maps:is_key(bind, Config)),
    ?assert(maps:is_key(pythonpath, Config)).

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

test_ssl_config(_Config) ->
    %% Test that SSL options are present in defaults
    Defaults = hornbeam_config:defaults(),
    ?assert(maps:is_key(ssl, Defaults)),
    ?assert(maps:is_key(certfile, Defaults)),
    ?assert(maps:is_key(keyfile, Defaults)),
    ?assert(maps:is_key(cacertfile, Defaults)),

    %% Verify default values
    ?assertEqual(false, maps:get(ssl, Defaults)),
    ?assertEqual(undefined, maps:get(certfile, Defaults)),
    ?assertEqual(undefined, maps:get(keyfile, Defaults)),
    ?assertEqual(undefined, maps:get(cacertfile, Defaults)),

    %% Test that SSL options can be set
    hornbeam_config:set_config(#{
        ssl => true,
        certfile => <<"/path/to/cert.pem">>,
        keyfile => <<"/path/to/key.pem">>,
        cacertfile => <<"/path/to/ca.pem">>
    }),
    ?assertEqual(true, hornbeam_config:get_config(ssl)),
    ?assertEqual(<<"/path/to/cert.pem">>, hornbeam_config:get_config(certfile)),
    ?assertEqual(<<"/path/to/key.pem">>, hornbeam_config:get_config(keyfile)),
    ?assertEqual(<<"/path/to/ca.pem">>, hornbeam_config:get_config(cacertfile)).

test_ssl_missing_certfile(_Config) ->
    %% Test that SSL start fails without certfile
    Result1 = hornbeam:start("hello_wsgi.app:application", #{
        ssl => true,
        keyfile => <<"/path/to/key.pem">>
    }),
    ?assertEqual({error, {missing_ssl_option, certfile}}, Result1),

    %% Test that SSL start fails without keyfile
    Result2 = hornbeam:start("hello_wsgi.app:application", #{
        ssl => true,
        certfile => <<"/path/to/cert.pem">>
    }),
    ?assertEqual({error, {missing_ssl_option, keyfile}}, Result2).

test_websocket_compress_config(_Config) ->
    %% Test that websocket_compress option is present in defaults
    Defaults = hornbeam_config:defaults(),
    ?assert(maps:is_key(websocket_compress, Defaults)),

    %% Verify default value
    ?assertEqual(false, maps:get(websocket_compress, Defaults)),

    %% Test that websocket_compress can be set
    hornbeam_config:set_config(#{websocket_compress => true}),
    ?assertEqual(true, hornbeam_config:get_config(websocket_compress)).

test_hooks_on_request(_Config) ->
    %% Initialize hooks
    hornbeam_http_hooks:set_hooks(#{}),

    %% Test without hook - should return unchanged request
    Request1 = #{method => <<"GET">>, path => <<"/test">>},
    ?assertEqual(Request1, hornbeam_http_hooks:run_on_request(Request1)),

    %% Test with hook - should modify request
    hornbeam_http_hooks:set_hooks(#{
        on_request => fun(Req) ->
            Req#{modified => true}
        end
    }),
    Request2 = #{method => <<"POST">>, path => <<"/api">>},
    Result2 = hornbeam_http_hooks:run_on_request(Request2),
    ?assertEqual(true, maps:get(modified, Result2)),
    ?assertEqual(<<"POST">>, maps:get(method, Result2)).

test_hooks_on_response(_Config) ->
    %% Initialize hooks
    hornbeam_http_hooks:set_hooks(#{}),

    %% Test without hook - should return unchanged response
    Response1 = #{status => 200, body => <<"OK">>},
    ?assertEqual(Response1, hornbeam_http_hooks:run_on_response(Response1)),

    %% Test with hook - should modify response
    hornbeam_http_hooks:set_hooks(#{
        on_response => fun(Resp) ->
            Headers = maps:get(headers, Resp, #{}),
            Resp#{headers => Headers#{<<"x-custom">> => <<"added">>}}
        end
    }),
    Response2 = #{status => 200, headers => #{}},
    Result2 = hornbeam_http_hooks:run_on_response(Response2),
    ?assertEqual(<<"added">>, maps:get(<<"x-custom">>, maps:get(headers, Result2))).

test_hooks_on_error(_Config) ->
    %% Initialize hooks
    hornbeam_http_hooks:set_hooks(#{}),

    %% Test without hook - should return default error
    {Code1, Body1} = hornbeam_http_hooks:run_on_error({error, test}, #{}),
    ?assertEqual(500, Code1),
    ?assertEqual(<<"Internal Server Error">>, Body1),

    %% Test with hook - should return custom error
    hornbeam_http_hooks:set_hooks(#{
        on_error => fun({timeout, _}, _Req) ->
            {504, <<"Gateway Timeout">>};
        (_, _Req) ->
            {500, <<"Custom Error">>}
        end
    }),
    {Code2, Body2} = hornbeam_http_hooks:run_on_error({timeout, 30000}, #{}),
    ?assertEqual(504, Code2),
    ?assertEqual(<<"Gateway Timeout">>, Body2),

    {Code3, Body3} = hornbeam_http_hooks:run_on_error({other, error}, #{}),
    ?assertEqual(500, Code3),
    ?assertEqual(<<"Custom Error">>, Body3).

test_hooks_exception_handling(_Config) ->
    %% Test that hook exceptions are caught and don't crash
    %% on_request hook that throws should return original request
    hornbeam_http_hooks:set_hooks(#{
        on_request => fun(_Req) ->
            error(intentional_crash)
        end
    }),
    Request = #{method => <<"GET">>, path => <<"/test">>},
    ?assertEqual(Request, hornbeam_http_hooks:run_on_request(Request)),

    %% on_response hook that throws should return original response
    hornbeam_http_hooks:set_hooks(#{
        on_response => fun(_Resp) ->
            throw(intentional_throw)
        end
    }),
    Response = #{status => 200},
    ?assertEqual(Response, hornbeam_http_hooks:run_on_response(Response)),

    %% on_error hook that throws should return default error
    hornbeam_http_hooks:set_hooks(#{
        on_error => fun(_, _) ->
            exit(intentional_exit)
        end
    }),
    {Code, Body} = hornbeam_http_hooks:run_on_error({error, test}, #{}),
    ?assertEqual(500, Code),
    ?assertEqual(<<"Internal Server Error">>, Body).

test_ipv6_parse(_Config) ->
    %% Test IPv6 bind address parsing using hornbeam module
    %% We can't call hornbeam:parse_bind directly as it's private,
    %% but we can verify the config accepts IPv6 format

    %% Test that IPv6 addresses can be configured
    hornbeam_config:set_config(#{bind => <<"[::]:8000">>}),
    ?assertEqual(<<"[::]:8000">>, hornbeam_config:get_config(bind)),

    hornbeam_config:set_config(#{bind => <<"[::1]:8080">>}),
    ?assertEqual(<<"[::1]:8080">>, hornbeam_config:get_config(bind)),

    %% Test that IPv6 with full address works
    hornbeam_config:set_config(#{bind => <<"[2001:db8::1]:9000">>}),
    ?assertEqual(<<"[2001:db8::1]:9000">>, hornbeam_config:get_config(bind)).
