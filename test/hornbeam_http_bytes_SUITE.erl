%% Real HTTP regressions crossing the Erlang/Python native boundary.
-module(hornbeam_http_bytes_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         scope_types/1, cookie/1, inline_bodies/1, large_body/1,
         response_complete/1, peer_disconnect/1, streaming_disconnect/1,
         request_timeout/1]).

all() -> [scope_types, cookie, inline_bodies, large_body, response_complete,
          peer_disconnect, streaming_disconnect, request_timeout].

init_per_suite(Config) ->
    _ = application:stop(hornbeam),
    _ = application:stop(erlang_python),
    {ok, _} = application:ensure_all_started(hornbeam),
    {ok, Loops} = py_event_loop_pool:get_all_loops(),
    ct:pal("Native HTTP event-loop pool size: ~p", [length(Loops)]),
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    %% Resolve the source checkout through rebar's src link, like the
    %% existing ASGI suite (the test app is not a production module).
    LibDir = filename:dirname(filename:dirname(code:which(hornbeam))),
    SourceDir = case file:read_link(filename:join(LibDir, "src")) of
        {ok, RelPath} ->
            filename:dirname(filename:absname(filename:join(LibDir, RelPath)));
        {error, _} -> LibDir
    end,
    AppDir = filename:join(SourceDir, "test/test_apps"),
    ok = hornbeam:start("http_bytes_app:application", #{
        bind => iolist_to_binary(["127.0.0.1:", integer_to_list(Port)]),
        worker_class => asgi,
        context_mode => worker,
        lifespan => off,
        timeout => 3000,
        pythonpath => [list_to_binary(AppDir)]
    }),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    hornbeam:stop(),
    application:stop(hornbeam),
    application:stop(erlang_python),
    ok.

scope_types(Config) ->
    %% The app asserts field types before responding. In particular, an
    %% ASCII-only header or query must not become str at the native boundary.
    Url = url(Config, <<"/caf%C3%A9?name=caf%C3%A9">>),
    {ok, #{status := 200, body := {full, Body}}} =
        hornbeam_test_http:request(get, Url),
    ?assertNotEqual(nomatch, binary:match(Body, <<"\"path\": \"/caf\\u00e9\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"\"raw_path\": \"/caf%C3%A9\"">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"\"query\": \"name=caf%C3%A9\"">>)).

cookie(Config) ->
    {ok, #{status := 200, body := {full, Body}}} =
        hornbeam_test_http:request(get, url(Config, <<"/cookie">>),
            #{headers => [{<<"Cookie">>, <<"probe=yes">>}]}),
    ?assertEqual(<<"yes">>, Body).

inline_bodies(Config) ->
    lists:foreach(fun(Body) -> assert_echo(Config, Body) end,
        [<<"hello">>, <<"café"/utf8>>, <<"雪"/utf8>>, <<255, 0, 128>>, <<>>]).

large_body(Config) ->
    %% Keep the already-correct raw ByteChannel path covered separately.
    assert_echo(Config, binary:copy(<<"café雪"/utf8>>, 12000)).

response_complete(Config) ->
    {ok, #{status := 200, body := {full, <<"ok">>}}} =
        hornbeam_test_http:request(get, url(Config, <<"/lifecycle/wait/complete">>)),
    await_state(Config, <<"complete">>, <<"done">>, 100).

peer_disconnect(Config) ->
    Socket = open_waiter(Config, <<"close">>),
    ok = gen_tcp:close(Socket),
    await_state(Config, <<"close">>, <<"done">>, 100).

streaming_disconnect(Config) ->
    Socket = open_waiter(Config, <<"stream">>),
    {ok, _ResponseHead} = gen_tcp:recv(Socket, 0, 1000),
    ok = gen_tcp:close(Socket),
    await_state(Config, <<"stream">>, <<"done">>, 100).

request_timeout(Config) ->
    Socket = open_waiter(Config, <<"timeout">>),
    try await_state(Config, <<"timeout">>, <<"done">>, 100)
    after gen_tcp:close(Socket) end.

open_waiter(Config, Name) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1},
        proplists:get_value(port, Config), [binary, {active, false}], 1000),
    ok = gen_tcp:send(Socket, [<<"GET /lifecycle/wait/">>, Name,
                               <<" HTTP/1.1\r\nHost: localhost\r\n\r\n">>]),
    await_state(Config, Name, <<"waiting">>, 100),
    Socket.

await_state(_Config, Name, Expected, 0) ->
    ct:fail({lifecycle_state_not_reached, Name, Expected});
await_state(Config, Name, Expected, Attempts) ->
    {ok, #{status := 200, body := {full, State}}} = hornbeam_test_http:request(
        get, url(Config, <<"/lifecycle/status/", Name/binary>>)),
    case State of
        Expected -> ok;
        _ ->
            case Attempts of 1 -> ct:pal("Last lifecycle state: ~p", [State]); _ -> ok end,
            receive after 50 -> ok end,
            await_state(Config, Name, Expected, Attempts - 1)
    end.

assert_echo(Config, Body) ->
    {ok, #{status := 200, body := {full, Echo}}} =
        hornbeam_test_http:request(post, url(Config, <<"/echo">>),
            #{headers => [{<<"Content-Type">>, <<"application/octet-stream">>}],
              body => Body}),
    ?assertEqual(Body, Echo).

url(Config, Path) ->
    iolist_to_binary(["http://127.0.0.1:",
                      integer_to_list(proplists:get_value(port, Config)), Path]).
