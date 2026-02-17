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

%%% @doc Tests for hornbeam presence tracking (ORSWOT CRDT).
-module(hornbeam_presence_SUITE).

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
    test_track_presence/1,
    test_untrack_presence/1,
    test_list_presences/1,
    test_get_by_key/1,
    test_update_presence/1,
    test_multiple_presences_same_key/1,
    test_untrack_all/1,
    test_process_monitor_cleanup/1,
    test_presence_diff_broadcast/1
]).

all() ->
    [{group, presence}].

groups() ->
    [{presence, [sequence], [
        test_track_presence,
        test_untrack_presence,
        test_list_presences,
        test_get_by_key,
        test_update_presence,
        test_multiple_presences_same_key,
        test_untrack_all,
        test_process_monitor_cleanup,
        test_presence_diff_broadcast
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

test_track_presence(_Config) ->
    Topic = <<"presence:test:track">>,
    Key = <<"user:1">>,
    Meta = #{<<"name">> => <<"Alice">>, <<"status">> => <<"online">>},

    %% Track presence
    ok = hornbeam_presence:track(Topic, self(), Key, Meta),

    %% Should be in list
    Presences = hornbeam_presence:list(Topic),
    ?assert(maps:is_key(Key, Presences)),

    KeyPresence = maps:get(Key, Presences),
    Metas = maps:get(<<"metas">>, KeyPresence),
    ?assertEqual(1, length(Metas)),

    %% Cleanup
    hornbeam_presence:untrack(Topic, self(), Key).

test_untrack_presence(_Config) ->
    Topic = <<"presence:test:untrack">>,
    Key = <<"user:2">>,
    Meta = #{<<"name">> => <<"Bob">>},

    ok = hornbeam_presence:track(Topic, self(), Key, Meta),
    ?assert(maps:is_key(Key, hornbeam_presence:list(Topic))),

    %% Untrack
    hornbeam_presence:untrack(Topic, self(), Key),

    %% Give it a moment to process
    timer:sleep(50),

    %% Should be gone
    Presences = hornbeam_presence:list(Topic),
    ?assertNot(maps:is_key(Key, Presences)).

test_list_presences(_Config) ->
    Topic = <<"presence:test:list">>,

    %% Track multiple presences
    ok = hornbeam_presence:track(Topic, self(), <<"user:a">>, #{<<"name">> => <<"A">>}),
    ok = hornbeam_presence:track(Topic, self(), <<"user:b">>, #{<<"name">> => <<"B">>}),
    ok = hornbeam_presence:track(Topic, self(), <<"user:c">>, #{<<"name">> => <<"C">>}),

    Presences = hornbeam_presence:list(Topic),
    ?assertEqual(3, maps:size(Presences)),
    ?assert(maps:is_key(<<"user:a">>, Presences)),
    ?assert(maps:is_key(<<"user:b">>, Presences)),
    ?assert(maps:is_key(<<"user:c">>, Presences)),

    %% Cleanup
    hornbeam_presence:untrack(Topic, self(), <<"user:a">>),
    hornbeam_presence:untrack(Topic, self(), <<"user:b">>),
    hornbeam_presence:untrack(Topic, self(), <<"user:c">>).

test_get_by_key(_Config) ->
    Topic = <<"presence:test:getkey">>,
    Key = <<"user:specific">>,
    Meta = #{<<"name">> => <<"Charlie">>, <<"role">> => <<"admin">>},

    ok = hornbeam_presence:track(Topic, self(), Key, Meta),

    %% Get specific key
    Result = hornbeam_presence:get_by_key(Topic, Key),
    ?assertNotEqual(undefined, Result),

    Metas = maps:get(<<"metas">>, Result),
    ?assertEqual(1, length(Metas)),
    [M] = Metas,
    ?assertEqual(<<"Charlie">>, maps:get(<<"name">>, M)),

    %% Non-existent key
    ?assertEqual(undefined, hornbeam_presence:get_by_key(Topic, <<"nonexistent">>)),

    %% Cleanup
    hornbeam_presence:untrack(Topic, self(), Key).

test_update_presence(_Config) ->
    Topic = <<"presence:test:update">>,
    Key = <<"user:updatable">>,

    %% Initial track
    ok = hornbeam_presence:track(Topic, self(), Key, #{<<"status">> => <<"online">>}),

    %% Update
    ok = hornbeam_presence:update(Topic, self(), Key, #{<<"status">> => <<"away">>}),

    %% Check updated value
    Result = hornbeam_presence:get_by_key(Topic, Key),
    Metas = maps:get(<<"metas">>, Result),
    ?assertEqual(1, length(Metas)),
    [M] = Metas,
    ?assertEqual(<<"away">>, maps:get(<<"status">>, M)),

    %% Cleanup
    hornbeam_presence:untrack(Topic, self(), Key).

test_multiple_presences_same_key(_Config) ->
    Topic = <<"presence:test:multi">>,
    Key = <<"user:multi">>,

    %% Spawn two processes for same user
    Self = self(),
    Pid1 = spawn_link(fun() ->
        ok = hornbeam_presence:track(Topic, self(), Key, #{<<"device">> => <<"phone">>}),
        Self ! {tracked, self()},
        receive stop -> ok end
    end),
    Pid2 = spawn_link(fun() ->
        ok = hornbeam_presence:track(Topic, self(), Key, #{<<"device">> => <<"desktop">>}),
        Self ! {tracked, self()},
        receive stop -> ok end
    end),

    %% Wait for both to track
    receive {tracked, Pid1} -> ok after 1000 -> ct:fail("Pid1 timeout") end,
    receive {tracked, Pid2} -> ok after 1000 -> ct:fail("Pid2 timeout") end,

    %% Should have 2 metas for same key
    Result = hornbeam_presence:get_by_key(Topic, Key),
    Metas = maps:get(<<"metas">>, Result),
    ?assertEqual(2, length(Metas)),

    %% Check both devices are present
    Devices = [maps:get(<<"device">>, M) || M <- Metas],
    ?assert(lists:member(<<"phone">>, Devices)),
    ?assert(lists:member(<<"desktop">>, Devices)),

    %% Cleanup
    Pid1 ! stop,
    Pid2 ! stop.

test_untrack_all(_Config) ->
    Topic = <<"presence:test:untrackall">>,

    %% Track multiple keys
    ok = hornbeam_presence:track(Topic, self(), <<"key:1">>, #{<<"n">> => 1}),
    ok = hornbeam_presence:track(Topic, self(), <<"key:2">>, #{<<"n">> => 2}),

    Presences1 = hornbeam_presence:list(Topic),
    ?assertEqual(2, maps:size(Presences1)),

    %% Untrack all for this process
    hornbeam_presence:untrack_all(Topic, self()),
    timer:sleep(50),

    %% Should be empty
    Presences2 = hornbeam_presence:list(Topic),
    ?assertEqual(0, maps:size(Presences2)).

test_process_monitor_cleanup(_Config) ->
    Topic = <<"presence:test:monitor">>,
    Key = <<"user:monitored">>,

    %% Spawn a process that tracks and then dies
    Self = self(),
    Pid = spawn(fun() ->
        ok = hornbeam_presence:track(Topic, self(), Key, #{<<"name">> => <<"Ephemeral">>}),
        Self ! {tracked, self()},
        receive never -> ok end  % Will be killed
    end),

    receive {tracked, Pid} -> ok after 1000 -> ct:fail("Track timeout") end,

    %% Verify presence exists
    ?assert(maps:is_key(Key, hornbeam_presence:list(Topic))),

    %% Kill the process
    exit(Pid, kill),
    timer:sleep(100),  % Give time for monitor cleanup

    %% Presence should be automatically removed
    ?assertNot(maps:is_key(Key, hornbeam_presence:list(Topic))).

test_presence_diff_broadcast(_Config) ->
    Topic = <<"presence:test:diff">>,
    Key = <<"user:difftest">>,

    %% Subscribe to topic for presence diffs
    hornbeam_pubsub:subscribe(Topic, self()),

    %% Track should trigger presence_diff with join
    ok = hornbeam_presence:track(Topic, self(), Key, #{<<"name">> => <<"DiffUser">>}),

    receive
        {pubsub, Topic, {presence_diff, Diff}} ->
            Joins = maps:get(<<"joins">>, Diff),
            ?assert(maps:is_key(Key, Joins))
    after 1000 ->
        ct:fail("Did not receive join presence_diff")
    end,

    %% Untrack should trigger presence_diff with leave
    hornbeam_presence:untrack(Topic, self(), Key),

    receive
        {pubsub, Topic, {presence_diff, Diff2}} ->
            Leaves = maps:get(<<"leaves">>, Diff2),
            ?assert(maps:is_key(Key, Leaves))
    after 1000 ->
        ct:fail("Did not receive leave presence_diff")
    end,

    %% Cleanup
    hornbeam_pubsub:unsubscribe(Topic).
