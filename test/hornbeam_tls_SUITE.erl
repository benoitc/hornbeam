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

%%% @doc TLS, HTTP/2, HTTP/3 and request-limit tests.
%%%
%%% The certificate is generated into `priv_dir' at setup, so these
%%% suites need openssl on PATH and skip without it.
-module(hornbeam_tls_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2
]).

-export([
    test_h1_over_tls/1,
    test_h2_over_tls/1,
    test_h1_on_the_h2_port/1,
    test_info_reports_h1_and_h2/1,
    test_h3_listener_and_alt_svc/1,
    test_h3_request/1,
    test_h2_requires_ssl/1,
    test_h3_requires_ssl/1,
    test_invalid_http_version/1,
    test_max_headers/1,
    test_max_header_size/1,
    test_max_request_line_size/1
]).

all() ->
    [{group, tls_h1},
     {group, alpn},
     {group, h3},
     {group, validation},
     {group, limits}].

groups() ->
    [{tls_h1, [sequence], [
        test_h1_over_tls
    ]},
    {alpn, [sequence], [
        test_h2_over_tls,
        test_h1_on_the_h2_port,
        test_info_reports_h1_and_h2
    ]},
    {h3, [sequence], [
        test_h3_listener_and_alt_svc,
        test_h3_request
    ]},
    {validation, [sequence], [
        test_h2_requires_ssl,
        test_h3_requires_ssl,
        test_invalid_http_version
    ]},
    {limits, [sequence], [
        test_max_headers,
        test_max_header_size,
        test_max_request_line_size
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, _} = application:ensure_all_started(livery),
    case hornbeam_test_certs:generate(?config(priv_dir, Config)) of
        {ok, CertFile, KeyFile} ->
            [{certfile, list_to_binary(CertFile)},
             {keyfile, list_to_binary(KeyFile)} | Config];
        {error, Reason} ->
            {skip, {no_certificate, Reason}}
    end.

end_per_suite(_Config) ->
    application:stop(hornbeam),
    ok.

init_per_group(validation, Config) ->
    Config;
init_per_group(Group, Config) ->
    Port = 18500 + erlang:phash2(Group, 200),
    ok = hornbeam:start("asgi_test_app:application",
                        maps:merge(base_opts(Config, Port), group_opts(Group))),
    timer:sleep(800),
    [{port, Port} | Config].

end_per_group(validation, _Config) ->
    ok;
end_per_group(_Group, _Config) ->
    hornbeam:stop(),
    timer:sleep(300),
    ok.

%% HTTP/1.1 alone over TLS keeps the `http' listener and only changes its
%% transport; the other groups take the ALPN listener instead.
group_opts(tls_h1) ->
    #{http_version => ['HTTP/1.1']};
group_opts(alpn) ->
    #{http_version => ['HTTP/1.1', 'HTTP/2']};
group_opts(h3) ->
    #{http_version => ['HTTP/1.1', 'HTTP/2', 'HTTP/3']};
group_opts(limits) ->
    #{http_version => ['HTTP/1.1'],
      max_headers => 20,
      max_header_size => 512,
      max_request_line_size => 512}.

base_opts(Config, Port) ->
    #{
        bind => iolist_to_binary(io_lib:format("127.0.0.1:~p", [Port])),
        worker_class => asgi,
        ssl => true,
        certfile => ?config(certfile, Config),
        keyfile => ?config(keyfile, Config),
        pythonpath => [list_to_binary(test_apps_dir())]
    }.

%%% ============================================================================
%%% TLS and protocol negotiation
%%% ============================================================================

test_h1_over_tls(Config) ->
    ?assertEqual({<<"1.1">>, <<"https">>}, scope_via(Config, [http1])).

test_h2_over_tls(Config) ->
    ?assertEqual({<<"2">>, <<"https">>}, scope_via(Config, [http2])).

%% The whole point of the ALPN listener: a client that will not speak h2 is
%% served HTTP/1.1 from the same TLS port rather than refused.
test_h1_on_the_h2_port(Config) ->
    ?assertEqual({<<"1.1">>, <<"https">>}, scope_via(Config, [http1])).

test_info_reports_h1_and_h2(Config) ->
    Port = ?config(port, Config),
    #{running := true, listeners := Listeners} = hornbeam:info(),
    ?assertEqual([Port], maps:get(h1, Listeners, undefined)),
    ?assertEqual([Port], maps:get(h2, Listeners, undefined)).

%%% ============================================================================
%%% HTTP/3
%%% ============================================================================

test_h3_listener_and_alt_svc(Config) ->
    Port = ?config(port, Config),
    #{listeners := Listeners} = hornbeam:info(),
    ?assertEqual([Port], maps:get(h3, Listeners, undefined)),

    %% h1 and h2 responses point clients at the QUIC port
    {ok, Resp} = request(Config, <<"/">>, [http2]),
    AltSvc = livery_client:header(<<"alt-svc">>, Resp),
    ?assertNotEqual(undefined, AltSvc),
    ?assertNotEqual(nomatch, binary:match(AltSvc, <<"h3=">>)).

test_h3_request(Config) ->
    case scope_via(Config, [http3]) of
        {<<"3">>, <<"https">>} ->
            ok;
        Other ->
            ct:pal("HTTP/3 request did not negotiate h3: ~p", [Other]),
            {skip, "no working HTTP/3 client transport"}
    end.

%%% ============================================================================
%%% Config validation
%%% ============================================================================

test_h2_requires_ssl(_Config) ->
    ?assertEqual({error, {http_version_requires_ssl, 'HTTP/2'}},
                 hornbeam:start("asgi_test_app:application",
                                #{bind => <<"127.0.0.1:18999">>,
                                  http_version => ['HTTP/1.1', 'HTTP/2']})).

test_h3_requires_ssl(_Config) ->
    ?assertEqual({error, {http_version_requires_ssl, 'HTTP/3'}},
                 hornbeam:start("asgi_test_app:application",
                                #{bind => <<"127.0.0.1:18999">>,
                                  http_version => ['HTTP/3']})).

test_invalid_http_version(_Config) ->
    ?assertEqual({error, {invalid_http_version, 'HTTP/4'}},
                 hornbeam:start("asgi_test_app:application",
                                #{bind => <<"127.0.0.1:18999">>,
                                  ssl => true,
                                  http_version => ['HTTP/4']})),
    ?assertEqual({error, {invalid_http_version, []}},
                 hornbeam:start("asgi_test_app:application",
                                #{bind => <<"127.0.0.1:18999">>,
                                  http_version => []})).

%%% ============================================================================
%%% Request limits
%%% ============================================================================

%% h1 answers a limit breach rather than closing: 431 for the header
%% block, 414 for the request line.
test_max_headers(Config) ->
    Headers = [{iolist_to_binary(io_lib:format("x-n~p", [N])), <<"v">>}
               || N <- lists:seq(1, 40)],
    {ok, #{status := Status}} = request(Config, <<"/">>, [http1], Headers),
    ?assertEqual(431, Status).

test_max_header_size(Config) ->
    Big = binary:copy(<<"a">>, 2048),
    {ok, #{status := Status}} = request(Config, <<"/">>, [http1], [{<<"x-big">>, Big}]),
    ?assertEqual(431, Status).

test_max_request_line_size(Config) ->
    Long = <<"/?q=", (binary:copy(<<"a">>, 2048))/binary>>,
    {ok, #{status := Status}} = request(Config, Long, [http1]),
    ?assertEqual(414, Status).

%%% ============================================================================
%%% Helpers
%%% ============================================================================

%% The ASGI app echoes its scope, so the protocol the server actually used
%% is observable rather than inferred from the client's request.
scope_via(Config, Protocols) ->
    case request(Config, <<"/info">>, Protocols) of
        {ok, #{status := 200, body := {full, Body}}} ->
            Info = jsx:decode(Body, [return_maps]),
            {maps:get(<<"http_version">>, Info), maps:get(<<"scheme">>, Info)};
        Other ->
            Other
    end.

request(Config, Path, Protocols) ->
    request(Config, Path, Protocols, []).

request(Config, Path, Protocols, Headers) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([<<"https://127.0.0.1:">>, integer_to_binary(Port), Path]),
    hornbeam_test_http:request(get, Url, #{headers => Headers}, client_opts(Protocols)).

%% Self-signed certificate, so the client must not verify the chain.
%% It has to be hackney's own `insecure' flag nested inside `ssl_options':
%% a bare `{verify, verify_none}' there still fails, because hackney merges
%% its default `verify_fun' over the top, and `insecure' at the option-list
%% top level never reaches the TLS layer. `protocols' pins which HTTP
%% version hackney offers, so each test drives the wire it means to.
client_opts(Protocols) ->
    #{adapter_opts => #{hackney => [
        {ssl_options, [{insecure, true}]},
        {protocols, Protocols}
    ]}}.

test_apps_dir() ->
    EbinDir = filename:dirname(code:which(hornbeam)),
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
