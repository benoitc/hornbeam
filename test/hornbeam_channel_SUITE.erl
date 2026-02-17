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

%%% @doc Tests for hornbeam channel process.
-module(hornbeam_channel_SUITE).

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
    test_start_link/1,
    test_heartbeat_reply/1,
    test_broadcast/1,
    test_broadcast_from/1,
    test_assign/1,
    test_get_assigns/1,
    test_push/1
]).

all() ->
    [{group, channel}].

groups() ->
    [{channel, [sequence], [
        test_start_link,
        test_heartbeat_reply,
        test_broadcast,
        test_broadcast_from,
        test_assign,
        test_get_assigns,
        test_push
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
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_start_link(_Config) ->
    SessionId = <<"test-session-1">>,
    {ok, Pid} = hornbeam_channel:start_link(self(), SessionId),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),

    %% Cleanup
    gen_server:stop(Pid).

test_heartbeat_reply(_Config) ->
    SessionId = <<"test-session-heartbeat">>,
    {ok, Pid} = hornbeam_channel:start_link(self(), SessionId),

    %% Send heartbeat message: [join_ref, ref, topic, event, payload]
    HeartbeatMsg = [null, <<"1">>, <<"hornbeam">>, <<"heartbeat">>, #{}],
    hornbeam_channel:handle_message(Pid, HeartbeatMsg),

    %% Should receive reply
    receive
        {websocket_send, text, Json} ->
            %% Json might be iolist, convert to binary first
            JsonBin = iolist_to_binary(Json),
            Decoded = json:decode(JsonBin),
            ?assertMatch([_, <<"1">>, <<"hornbeam">>, <<"hb_reply">>, _], Decoded),
            [_, _, _, _, Response] = Decoded,
            ?assertEqual(<<"ok">>, maps:get(<<"status">>, Response))
    after 1000 ->
        ct:fail("Did not receive heartbeat reply")
    end,

    gen_server:stop(Pid).

test_broadcast(_Config) ->
    Topic = <<"channel:broadcast:test">>,

    %% Subscribe to topic
    hornbeam_pubsub:subscribe(Topic, self()),

    %% Broadcast
    hornbeam_channel:broadcast(Topic, <<"new_msg">>, #{<<"body">> => <<"Hello">>}),

    %% Should receive the broadcast
    receive
        {pubsub, Topic, {channel_broadcast, <<"new_msg">>, Payload}} ->
            ?assertEqual(<<"Hello">>, maps:get(<<"body">>, Payload))
    after 1000 ->
        ct:fail("Did not receive broadcast")
    end,

    hornbeam_pubsub:unsubscribe(Topic).

test_broadcast_from(_Config) ->
    Topic = <<"channel:broadcastfrom:test">>,
    SenderPid = self(),

    %% Spawn a receiver
    TestPid = self(),
    ReceiverPid = spawn_link(fun() ->
        hornbeam_pubsub:subscribe(Topic, self()),
        TestPid ! receiver_ready,
        receive
            {pubsub, Topic, {channel_broadcast_from, _, Event, Payload}} ->
                TestPid ! {received, Event, Payload}
        after 2000 ->
            TestPid ! timeout
        end
    end),

    receive receiver_ready -> ok after 1000 -> ct:fail("Receiver not ready") end,

    %% Also subscribe the sender
    hornbeam_pubsub:subscribe(Topic, self()),

    %% Broadcast from sender
    hornbeam_channel:broadcast_from(SenderPid, Topic, <<"msg">>, #{<<"n">> => 1}),

    %% Receiver should get it
    receive
        {received, <<"msg">>, #{<<"n">> := 1}} -> ok
    after 1000 ->
        ct:fail("Receiver did not get broadcast_from")
    end,

    %% Sender should also get it (but channel process would filter it)
    receive
        {pubsub, Topic, {channel_broadcast_from, _, _, _}} -> ok
    after 1000 ->
        ct:fail("Sender did not receive message")
    end,

    hornbeam_pubsub:unsubscribe(Topic).

test_assign(_Config) ->
    SessionId = <<"test-session-assign">>,
    {ok, Pid} = hornbeam_channel:start_link(self(), SessionId),

    %% Assign value
    hornbeam_channel:assign(Pid, user_id, <<"user123">>),
    hornbeam_channel:assign(Pid, role, admin),

    %% Get assigns
    Assigns = hornbeam_channel:get_assigns(Pid),
    ?assertEqual(<<"user123">>, maps:get(user_id, Assigns)),
    ?assertEqual(admin, maps:get(role, Assigns)),

    gen_server:stop(Pid).

test_get_assigns(_Config) ->
    SessionId = <<"test-session-getassigns">>,
    {ok, Pid} = hornbeam_channel:start_link(self(), SessionId),

    %% Initially empty
    Assigns1 = hornbeam_channel:get_assigns(Pid),
    ?assertEqual(#{}, Assigns1),

    %% Add some assigns
    hornbeam_channel:assign(Pid, key1, value1),
    hornbeam_channel:assign(Pid, key2, value2),

    Assigns2 = hornbeam_channel:get_assigns(Pid),
    ?assertEqual(2, maps:size(Assigns2)),

    gen_server:stop(Pid).

test_push(_Config) ->
    SessionId = <<"test-session-push">>,
    {ok, Pid} = hornbeam_channel:start_link(self(), SessionId),
    Topic = <<"test:push">>,

    %% Push a message
    hornbeam_channel:push(Pid, Topic, <<"event">>, #{<<"data">> => <<"test">>}),

    %% Should receive websocket_send
    receive
        {websocket_send, text, Json} ->
            JsonBin = iolist_to_binary(Json),
            Decoded = json:decode(JsonBin),
            %% Format: [join_ref, ref, topic, event, payload]
            ?assertMatch([_, _, Topic, <<"event">>, _], Decoded),
            [_, _, _, _, Payload] = Decoded,
            ?assertEqual(<<"test">>, maps:get(<<"data">>, Payload))
    after 1000 ->
        ct:fail("Did not receive push message")
    end,

    gen_server:stop(Pid).
