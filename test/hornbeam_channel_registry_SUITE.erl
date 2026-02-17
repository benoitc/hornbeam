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

%%% @doc Tests for hornbeam channel registry (topic pattern matching).
-module(hornbeam_channel_registry_SUITE).

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
    test_register_exact_pattern/1,
    test_register_wildcard_pattern/1,
    test_find_handler_exact_match/1,
    test_find_handler_wildcard_match/1,
    test_find_handler_no_match/1,
    test_parse_topic_params_single_wildcard/1,
    test_parse_topic_params_multiple_wildcards/1,
    test_unregister_pattern/1,
    test_list_handlers/1,
    test_pattern_priority/1
]).

all() ->
    [{group, registry}].

groups() ->
    [{registry, [sequence], [
        test_register_exact_pattern,
        test_register_wildcard_pattern,
        test_find_handler_exact_match,
        test_find_handler_wildcard_match,
        test_find_handler_no_match,
        test_parse_topic_params_single_wildcard,
        test_parse_topic_params_multiple_wildcards,
        test_unregister_pattern,
        test_list_handlers,
        test_pattern_priority
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
    %% Clean up any previous handlers
    lists:foreach(fun({Pattern, _}) ->
        hornbeam_channel_registry:unregister(Pattern)
    end, hornbeam_channel_registry:list_handlers()),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_register_exact_pattern(_Config) ->
    Pattern = <<"room:lobby">>,
    HandlerInfo = #{module => test_handler, type => erlang},

    %% Register
    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    %% Should be in list
    Handlers = hornbeam_channel_registry:list_handlers(),
    ?assertEqual(1, length(Handlers)),
    ?assert(lists:any(fun({P, _}) -> P =:= Pattern end, Handlers)).

test_register_wildcard_pattern(_Config) ->
    Pattern = <<"room:*">>,
    HandlerInfo = #{module => wildcard_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    Handlers = hornbeam_channel_registry:list_handlers(),
    ?assertEqual(1, length(Handlers)).

test_find_handler_exact_match(_Config) ->
    Pattern = <<"chat:lobby">>,
    HandlerInfo = #{module => chat_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    %% Exact match should work
    {ok, Handler} = hornbeam_channel_registry:find_handler(<<"chat:lobby">>),
    ?assertEqual(chat_handler, element(5, Handler)).  % module field

test_find_handler_wildcard_match(_Config) ->
    Pattern = <<"game:*">>,
    HandlerInfo = #{module => game_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    %% Wildcard match
    {ok, Handler1} = hornbeam_channel_registry:find_handler(<<"game:123">>),
    ?assertEqual(game_handler, element(5, Handler1)),

    {ok, Handler2} = hornbeam_channel_registry:find_handler(<<"game:lobby">>),
    ?assertEqual(game_handler, element(5, Handler2)),

    {ok, Handler3} = hornbeam_channel_registry:find_handler(<<"game:abc">>),
    ?assertEqual(game_handler, element(5, Handler3)).

test_find_handler_no_match(_Config) ->
    Pattern = <<"users:*">>,
    HandlerInfo = #{module => users_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    %% Non-matching topics
    ?assertEqual({error, no_handler}, hornbeam_channel_registry:find_handler(<<"rooms:123">>)),
    ?assertEqual({error, no_handler}, hornbeam_channel_registry:find_handler(<<"user:123">>)),
    ?assertEqual({error, no_handler}, hornbeam_channel_registry:find_handler(<<"other">>)).

test_parse_topic_params_single_wildcard(_Config) ->
    Pattern = <<"room:*">>,
    HandlerInfo = #{module => room_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    {ok, Handler} = hornbeam_channel_registry:find_handler(<<"room:123">>),
    Params = hornbeam_channel_registry:parse_topic_params(Handler, <<"room:123">>),

    %% Should extract room_id
    ?assertEqual(<<"123">>, maps:get(<<"room_id">>, Params)).

test_parse_topic_params_multiple_wildcards(_Config) ->
    Pattern = <<"chat:*:messages:*">>,
    HandlerInfo = #{module => chat_msg_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),

    {ok, Handler} = hornbeam_channel_registry:find_handler(<<"chat:lobby:messages:42">>),
    Params = hornbeam_channel_registry:parse_topic_params(Handler, <<"chat:lobby:messages:42">>),

    %% Should extract both params
    ?assertEqual(<<"lobby">>, maps:get(<<"chat_id">>, Params)),
    ?assertEqual(<<"42">>, maps:get(<<"messages_id">>, Params)).

test_unregister_pattern(_Config) ->
    Pattern = <<"temp:*">>,
    HandlerInfo = #{module => temp_handler, type => erlang},

    ok = hornbeam_channel_registry:register(Pattern, HandlerInfo),
    {ok, _} = hornbeam_channel_registry:find_handler(<<"temp:test">>),

    %% Unregister
    ok = hornbeam_channel_registry:unregister(Pattern),

    %% Should not find anymore
    ?assertEqual({error, no_handler}, hornbeam_channel_registry:find_handler(<<"temp:test">>)).

test_list_handlers(_Config) ->
    %% Register multiple handlers
    ok = hornbeam_channel_registry:register(<<"list:a">>, #{module => a, type => erlang}),
    ok = hornbeam_channel_registry:register(<<"list:b">>, #{module => b, type => erlang}),
    ok = hornbeam_channel_registry:register(<<"list:*">>, #{module => c, type => erlang}),

    Handlers = hornbeam_channel_registry:list_handlers(),
    ?assertEqual(3, length(Handlers)),

    Patterns = [P || {P, _} <- Handlers],
    ?assert(lists:member(<<"list:a">>, Patterns)),
    ?assert(lists:member(<<"list:b">>, Patterns)),
    ?assert(lists:member(<<"list:*">>, Patterns)).

test_pattern_priority(_Config) ->
    %% Register both exact and wildcard for same-looking topic
    ok = hornbeam_channel_registry:register(<<"prio:exact">>, #{module => exact, type => erlang}),
    ok = hornbeam_channel_registry:register(<<"prio:*">>, #{module => wildcard, type => erlang}),

    %% Exact match should take priority
    {ok, Handler1} = hornbeam_channel_registry:find_handler(<<"prio:exact">>),
    ?assertEqual(exact, element(5, Handler1)),

    %% Wildcard should match other topics
    {ok, Handler2} = hornbeam_channel_registry:find_handler(<<"prio:other">>),
    ?assertEqual(wildcard, element(5, Handler2)).
