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

%%% @doc Tests for hornbeam pub/sub messaging.
-module(hornbeam_pubsub_SUITE).

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
    test_subscribe_unsubscribe/1,
    test_publish_single_subscriber/1,
    test_publish_multiple_subscribers/1,
    test_get_members/1,
    test_multiple_topics/1,
    test_subscriber_receives_messages/1,
    test_unsubscribed_no_messages/1,
    test_binary_topic/1,
    test_tuple_topic/1
]).

all() ->
    [{group, pubsub}].

groups() ->
    [{pubsub, [sequence], [
        test_subscribe_unsubscribe,
        test_publish_single_subscriber,
        test_publish_multiple_subscribers,
        test_get_members,
        test_multiple_topics,
        test_subscriber_receives_messages,
        test_unsubscribed_no_messages,
        test_binary_topic,
        test_tuple_topic
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
    %% Clean up any subscriptions for this process
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_subscribe_unsubscribe(_Config) ->
    Topic = test_topic_1,

    %% Initially no members
    ?assertEqual([], hornbeam_pubsub:get_members(Topic)),

    %% Subscribe
    ok = hornbeam_pubsub:subscribe(Topic),
    Members = hornbeam_pubsub:get_members(Topic),
    ?assertEqual(1, length(Members)),
    ?assert(lists:member(self(), Members)),

    %% Unsubscribe
    ok = hornbeam_pubsub:unsubscribe(Topic),
    ?assertEqual([], hornbeam_pubsub:get_members(Topic)).

test_publish_single_subscriber(_Config) ->
    Topic = test_topic_2,

    %% Subscribe
    ok = hornbeam_pubsub:subscribe(Topic),

    %% Publish
    Count = hornbeam_pubsub:publish(Topic, hello),
    ?assertEqual(1, Count),

    %% Check message received
    receive
        {pubsub, Topic, hello} -> ok
    after 1000 ->
        ct:fail("Did not receive published message")
    end,

    %% Cleanup
    ok = hornbeam_pubsub:unsubscribe(Topic).

test_publish_multiple_subscribers(_Config) ->
    Topic = test_topic_3,
    Self = self(),

    %% Spawn additional subscribers
    Pid1 = spawn_link(fun() -> subscriber_loop(Self) end),
    Pid2 = spawn_link(fun() -> subscriber_loop(Self) end),

    %% Subscribe all
    ok = hornbeam_pubsub:subscribe(Topic),
    ok = hornbeam_pubsub:subscribe(Topic, Pid1),
    ok = hornbeam_pubsub:subscribe(Topic, Pid2),

    %% Verify 3 members
    Members = hornbeam_pubsub:get_members(Topic),
    ?assertEqual(3, length(Members)),

    %% Publish
    Count = hornbeam_pubsub:publish(Topic, broadcast_msg),
    ?assertEqual(3, Count),

    %% Check all received
    receive
        {pubsub, Topic, broadcast_msg} -> ok
    after 1000 ->
        ct:fail("Main process did not receive message")
    end,

    %% Check spawned processes received
    receive
        {subscriber_received, Pid1, broadcast_msg} -> ok
    after 1000 ->
        ct:fail("Pid1 did not receive message")
    end,

    receive
        {subscriber_received, Pid2, broadcast_msg} -> ok
    after 1000 ->
        ct:fail("Pid2 did not receive message")
    end,

    %% Cleanup
    ok = hornbeam_pubsub:unsubscribe(Topic),
    ok = hornbeam_pubsub:unsubscribe(Topic, Pid1),
    ok = hornbeam_pubsub:unsubscribe(Topic, Pid2),
    Pid1 ! stop,
    Pid2 ! stop.

test_get_members(_Config) ->
    Topic = test_topic_4,

    %% Subscribe self
    ok = hornbeam_pubsub:subscribe(Topic),

    %% get_members should include self
    Members = hornbeam_pubsub:get_members(Topic),
    ?assert(lists:member(self(), Members)),

    %% get_local_members should also include self (same node)
    LocalMembers = hornbeam_pubsub:get_local_members(Topic),
    ?assert(lists:member(self(), LocalMembers)),

    %% Cleanup
    ok = hornbeam_pubsub:unsubscribe(Topic).

test_multiple_topics(_Config) ->
    Topic1 = multi_topic_1,
    Topic2 = multi_topic_2,

    %% Subscribe to both topics
    ok = hornbeam_pubsub:subscribe(Topic1),
    ok = hornbeam_pubsub:subscribe(Topic2),

    %% Verify membership in both
    ?assert(lists:member(self(), hornbeam_pubsub:get_members(Topic1))),
    ?assert(lists:member(self(), hornbeam_pubsub:get_members(Topic2))),

    %% Publish to Topic1
    hornbeam_pubsub:publish(Topic1, msg1),

    receive
        {pubsub, Topic1, msg1} -> ok
    after 1000 ->
        ct:fail("Did not receive Topic1 message")
    end,

    %% Publish to Topic2
    hornbeam_pubsub:publish(Topic2, msg2),

    receive
        {pubsub, Topic2, msg2} -> ok
    after 1000 ->
        ct:fail("Did not receive Topic2 message")
    end,

    %% Cleanup
    ok = hornbeam_pubsub:unsubscribe(Topic1),
    ok = hornbeam_pubsub:unsubscribe(Topic2).

test_subscriber_receives_messages(_Config) ->
    Topic = receive_test_topic,

    ok = hornbeam_pubsub:subscribe(Topic),

    %% Publish multiple messages
    hornbeam_pubsub:publish(Topic, msg_a),
    hornbeam_pubsub:publish(Topic, msg_b),
    hornbeam_pubsub:publish(Topic, msg_c),

    %% Should receive all in order
    receive {pubsub, Topic, msg_a} -> ok after 1000 -> ct:fail("Missing msg_a") end,
    receive {pubsub, Topic, msg_b} -> ok after 1000 -> ct:fail("Missing msg_b") end,
    receive {pubsub, Topic, msg_c} -> ok after 1000 -> ct:fail("Missing msg_c") end,

    ok = hornbeam_pubsub:unsubscribe(Topic).

test_unsubscribed_no_messages(_Config) ->
    Topic = unsub_test_topic,

    ok = hornbeam_pubsub:subscribe(Topic),
    ok = hornbeam_pubsub:unsubscribe(Topic),

    %% Publish after unsubscribe
    Count = hornbeam_pubsub:publish(Topic, should_not_receive),
    ?assertEqual(0, Count),

    %% Ensure no message received
    receive
        {pubsub, Topic, _} -> ct:fail("Should not receive message after unsubscribe")
    after 100 ->
        ok
    end.

test_binary_topic(_Config) ->
    Topic = <<"binary_topic">>,

    ok = hornbeam_pubsub:subscribe(Topic),
    hornbeam_pubsub:publish(Topic, binary_msg),

    receive
        {pubsub, <<"binary_topic">>, binary_msg} -> ok
    after 1000 ->
        ct:fail("Did not receive binary topic message")
    end,

    ok = hornbeam_pubsub:unsubscribe(Topic).

test_tuple_topic(_Config) ->
    Topic = {room, <<"chat123">>},

    ok = hornbeam_pubsub:subscribe(Topic),
    hornbeam_pubsub:publish(Topic, {chat, <<"Hello!">>}),

    receive
        {pubsub, {room, <<"chat123">>}, {chat, <<"Hello!">>}} -> ok
    after 1000 ->
        ct:fail("Did not receive tuple topic message")
    end,

    ok = hornbeam_pubsub:unsubscribe(Topic).

%%% ============================================================================
%%% Helper functions
%%% ============================================================================

subscriber_loop(Parent) ->
    receive
        {pubsub, _Topic, Msg} ->
            Parent ! {subscriber_received, self(), Msg},
            subscriber_loop(Parent);
        stop ->
            ok
    end.
