%% Compile hornbeam_asgi with +export_all into an isolated test directory.
%% py_byte_channel here is the HTTP-specific deterministic test double.
-module(hornbeam_http_lifecycle_tests).
-include_lib("eunit/include/eunit.hrl").

state(Timeout) ->
    erase(http_body_attempts),
    erase(http_body_closed),
    #{channel => test_channel, timeout_ms => Timeout}.

busy_deadline_test() ->
    Start = erlang:monotonic_time(millisecond),
    ?assertEqual({error, body_channel_timeout},
                 hornbeam_asgi:push_to_channel(state(25), <<255, 0, 128>>)),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assert(Elapsed >= 25),
    ?assert(Elapsed < 1000),
    ?assertEqual(true, get(http_body_closed)),
    ?assert(length(get(http_body_attempts)) < 10).

retry_preserves_bytes_test() ->
    Data = <<255, 0, 128, "café"/utf8>>,
    put(http_body_send_results, [busy, busy, ok]),
    ?assertEqual(ok, hornbeam_asgi:push_to_channel(state(1000), Data)),
    ?assertEqual([Data, Data, Data], get(http_body_attempts)),
    ?assertNotEqual(true, get(http_body_closed)).

closed_is_failure_test() ->
    put(http_body_send_results, [{error, closed}]),
    ?assertEqual({error, {body_channel, closed}},
                 hornbeam_asgi:push_to_channel(state(1000), <<"data">>)),
    ?assertEqual(true, get(http_body_closed)).

terminal_messages_test_() ->
    [?_test(assert_terminal(Msg)) || Msg <- [
        {livery_disconnect, make_ref(), peer_closed},
        <<"fin">>,
        {<<"error">>, <<"app failed">>},
        {async_result, make_ref(), {error, app_failed}}
    ]].

assert_terminal(Msg) ->
    self() ! unrelated,
    self() ! Msg,
    Start = erlang:monotonic_time(millisecond),
    ?assertEqual({error, interrupted},
                 hornbeam_asgi:push_to_channel(state(5000), <<"data">>)),
    ?assert(erlang:monotonic_time(millisecond) - Start < 1000),
    ?assertEqual(true, get(http_body_closed)),
    receive unrelated -> ok after 0 -> error(lost_unrelated) end,
    receive Msg -> ok after 0 -> error(lost_terminal) end.

disconnect_arrives_during_retry_test() ->
    Parent = self(),
    Msg = {livery_disconnect, make_ref(), peer_closed},
    spawn(fun() -> receive after 15 -> Parent ! Msg end end),
    ?assertEqual({error, interrupted},
                 hornbeam_asgi:push_to_channel(state(1000), <<"data">>)),
    ?assertEqual(true, get(http_body_closed)),
    receive Msg -> ok after 0 -> error(lost_terminal) end.

stream_timeout_returns_failure_test() ->
    Ref = make_ref(),
    self() ! {livery_body, Ref, {data, <<"data">>}},
    St = (state(25))#{body_ref => Ref},
    ?assertEqual({error, body_channel_timeout},
                 hornbeam_asgi:stream_loop(fun(_) -> ok end, St)),
    ?assertEqual(true, get(http_body_closed)).

stream_fin_during_busy_send_test() ->
    Ref = make_ref(),
    self() ! {livery_body, Ref, {data, <<"data">>}},
    self() ! <<"fin">>,
    St = (state(1000))#{body_ref => Ref},
    ?assertEqual(ok, hornbeam_asgi:stream_loop(fun(_) -> ok end, St)),
    ?assertEqual(true, get(http_body_closed)),
    receive <<"fin">> -> error(unhandled_fin) after 0 -> ok end.

stream_errors_during_busy_send_test_() ->
    [?_test(assert_stream_error(Msg)) || Msg <- [
        {<<"error">>, app_failed},
        {async_result, make_ref(), {error, app_failed}}
    ]].

assert_stream_error(Msg) ->
    Ref = make_ref(),
    self() ! {livery_body, Ref, {data, <<"data">>}},
    self() ! Msg,
    St = (state(1000))#{body_ref => Ref},
    ?assertEqual({error, app_failed}, hornbeam_asgi:stream_loop(fun(_) -> ok end, St)),
    ?assertEqual(true, get(http_body_closed)).

stream_disconnect_during_busy_send_test() ->
    Ref = make_ref(),
    self() ! {livery_body, Ref, {data, <<"data">>}},
    self() ! {livery_disconnect, Ref, peer_closed},
    St = (state(1000))#{body_ref => Ref},
    ?assertEqual({error, closed}, hornbeam_asgi:stream_loop(fun(_) -> ok end, St)),
    ?assertEqual(true, get(http_body_closed)).
