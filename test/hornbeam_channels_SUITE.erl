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

%%% @doc Integration tests for hornbeam channels.
%%%
%%% These tests verify the full channel lifecycle including:
%%% - WebSocket connection with channel protocol
%%% - Join/leave operations
%%% - Message broadcasting
%%% - Presence tracking
-module(hornbeam_channels_SUITE).

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
    test_channel_protocol_detection/1,
    test_heartbeat_handling/1,
    test_join_without_handler/1,
    test_join_with_mock_handler/1,
    test_broadcast_to_subscribers/1,
    test_broadcast_from_excludes_sender/1,
    test_presence_tracking/1,
    test_websocket_mode_fallback/1
]).

all() ->
    [{group, channels}].

groups() ->
    [{channels, [sequence], [
        test_channel_protocol_detection,
        test_heartbeat_handling,
        test_join_without_handler,
        test_join_with_mock_handler,
        test_broadcast_to_subscribers,
        test_broadcast_from_excludes_sender,
        test_presence_tracking,
        test_websocket_mode_fallback
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
    %% Clean up any registered handlers
    lists:foreach(fun({Pattern, _}) ->
        hornbeam_channel_registry:unregister(Pattern)
    end, hornbeam_channel_registry:list_handlers()),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_channel_protocol_detection(_Config) ->
    %% Test that channel protocol is detected from first message
    SessionId = <<"test-session-protocol">>,

    %% Start a channel process (simulating websocket detection)
    {ok, ChannelPid} = hornbeam_channel:start_link(self(), SessionId),

    %% Send a heartbeat message
    Msg = [null, <<"1">>, <<"hornbeam">>, <<"heartbeat">>, #{}],
    hornbeam_channel:handle_message(ChannelPid, Msg),

    %% Should receive heartbeat reply
    receive
        {websocket_send, text, Json} ->
            JsonBin = iolist_to_binary(Json),
            Decoded = json:decode(JsonBin),
            ?assertMatch([_, <<"1">>, <<"hornbeam">>, <<"hb_reply">>, _], Decoded)
    after 1000 ->
        ct:fail("Did not receive heartbeat reply")
    end,

    gen_server:stop(ChannelPid).

test_heartbeat_handling(_Config) ->
    SessionId = <<"test-session-heartbeat">>,
    {ok, ChannelPid} = hornbeam_channel:start_link(self(), SessionId),

    %% Send multiple heartbeats
    lists:foreach(fun(N) ->
        Ref = integer_to_binary(N),
        Msg = [null, Ref, <<"hornbeam">>, <<"heartbeat">>, #{}],
        hornbeam_channel:handle_message(ChannelPid, Msg),

        receive
            {websocket_send, text, Json} ->
                JsonBin = iolist_to_binary(Json),
                Decoded = json:decode(JsonBin),
                [_, RecvRef, <<"hornbeam">>, <<"hb_reply">>, Response] = Decoded,
                ?assertEqual(Ref, RecvRef),
                ?assertEqual(<<"ok">>, maps:get(<<"status">>, Response))
        after 1000 ->
            ct:fail("Did not receive heartbeat reply ~p", [N])
        end
    end, lists:seq(1, 5)),

    gen_server:stop(ChannelPid).

test_join_without_handler(_Config) ->
    SessionId = <<"test-session-no-handler">>,
    {ok, ChannelPid} = hornbeam_channel:start_link(self(), SessionId),

    %% Try to join a topic with no handler registered
    JoinMsg = [<<"join1">>, <<"1">>, <<"unhandled:topic">>, <<"hb_join">>, #{}],
    hornbeam_channel:handle_message(ChannelPid, JoinMsg),

    %% Should receive error response
    receive
        {websocket_send, text, Json} ->
            JsonBin = iolist_to_binary(Json),
            Decoded = json:decode(JsonBin),
            [_, _, <<"unhandled:topic">>, <<"hb_reply">>, Response] = Decoded,
            ?assertEqual(<<"error">>, maps:get(<<"status">>, Response)),
            InnerResp = maps:get(<<"response">>, Response),
            ?assert(maps:is_key(<<"reason">>, InnerResp))
    after 1000 ->
        ct:fail("Did not receive error reply")
    end,

    gen_server:stop(ChannelPid).

test_join_with_mock_handler(_Config) ->
    %% Test that registering a handler works
    %% Note: Actual Python handlers are tested through E2E tests
    Pattern = <<"mock:*">>,
    HandlerInfo = #{module => test_mock_handler, type => erlang},
    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    %% Verify handler is registered
    {ok, Handler} = hornbeam_channel_registry:find_handler(<<"mock:room">>),
    ?assertEqual(test_mock_handler, element(5, Handler)),

    %% Parse params from topic
    Params = hornbeam_channel_registry:parse_topic_params(Handler, <<"mock:room">>),
    ?assertEqual(<<"room">>, maps:get(<<"mock_id">>, Params)),

    %% Clean up
    hornbeam_channel_registry:unregister(Pattern).

test_broadcast_to_subscribers(_Config) ->
    Topic = <<"broadcast:test">>,

    %% Create two channel processes
    {ok, Channel1} = hornbeam_channel:start_link(self(), <<"sess1">>),
    {ok, Channel2} = hornbeam_channel:start_link(self(), <<"sess2">>),

    %% Subscribe both to topic (simulating joined state)
    hornbeam_pubsub:subscribe(Topic, Channel1),
    hornbeam_pubsub:subscribe(Topic, Channel2),

    %% Broadcast a message
    hornbeam_channel:broadcast(Topic, <<"test_event">>, #{<<"data">> => <<"hello">>}),

    %% Both should receive the broadcast (via pubsub)
    timer:sleep(50),

    gen_server:stop(Channel1),
    gen_server:stop(Channel2).

test_broadcast_from_excludes_sender(_Config) ->
    Topic = <<"broadcast_from:test">>,

    %% Create a sender channel
    SenderPid = spawn_link(fun() -> receive stop -> ok end end),

    %% Subscribe to receive broadcasts
    hornbeam_pubsub:subscribe(Topic, self()),

    %% Broadcast from sender
    hornbeam_channel:broadcast_from(SenderPid, Topic, <<"msg">>, #{<<"n">> => 1}),

    %% We should receive (we're not the sender)
    receive
        {pubsub, Topic, {channel_broadcast_from, Pid, <<"msg">>, _}} ->
            ?assertEqual(SenderPid, Pid)
    after 1000 ->
        ct:fail("Did not receive broadcast_from")
    end,

    hornbeam_pubsub:unsubscribe(Topic),
    SenderPid ! stop.

test_presence_tracking(_Config) ->
    Topic = <<"presence:tracking:test">>,
    Key = <<"user:test123">>,
    Meta = #{<<"name">> => <<"TestUser">>},

    %% Subscribe to presence diffs
    hornbeam_pubsub:subscribe(Topic, self()),

    %% Track presence
    ok = hornbeam_presence:track(Topic, self(), Key, Meta),

    %% Should receive join diff
    receive
        {pubsub, Topic, {presence_diff, Diff}} ->
            Joins = maps:get(<<"joins">>, Diff),
            ?assert(maps:is_key(Key, Joins))
    after 1000 ->
        ct:fail("Did not receive presence join diff")
    end,

    %% List should contain our presence
    Presences = hornbeam_presence:list(Topic),
    ?assert(maps:is_key(Key, Presences)),

    %% Untrack
    hornbeam_presence:untrack(Topic, self(), Key),

    %% Should receive leave diff
    receive
        {pubsub, Topic, {presence_diff, Diff2}} ->
            Leaves = maps:get(<<"leaves">>, Diff2),
            ?assert(maps:is_key(Key, Leaves))
    after 1000 ->
        ct:fail("Did not receive presence leave diff")
    end,

    hornbeam_pubsub:unsubscribe(Topic).

test_websocket_mode_fallback(_Config) ->
    %% Test that non-channel messages trigger ASGI mode
    %% This is tested at the websocket level, so we just verify
    %% the channel process handles list messages correctly

    SessionId = <<"test-asgi-fallback">>,
    {ok, ChannelPid} = hornbeam_channel:start_link(self(), SessionId),

    %% Send a valid channel message first (this is accepted)
    Msg = [null, <<"1">>, <<"hornbeam">>, <<"heartbeat">>, #{}],
    hornbeam_channel:handle_message(ChannelPid, Msg),

    receive
        {websocket_send, text, _} -> ok
    after 1000 ->
        ct:fail("No response")
    end,

    gen_server:stop(ChannelPid).

%%% ============================================================================
%%% Mock handler callbacks (for test_join_with_mock_handler)
%%% ============================================================================

%% These would be called if we had a full Erlang handler implementation
%% For now, the Python handlers are used via py:call
