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

%%% @doc Channel registry for topic pattern matching and handler dispatch.
%%%
%%% This module maintains a registry of channel handlers keyed by topic patterns.
%%% It supports wildcard matching:
%%% - Exact match: "room:lobby" matches only "room:lobby"
%%% - Wildcard: "room:*" matches "room:lobby", "room:123", etc.
%%% - Multi-segment wildcard: "chat:*:*" matches "chat:room:123"
%%%
%%% Handlers are typically Python functions registered via the channel() decorator.
-module(hornbeam_channel_registry).

-behaviour(gen_server).

-export([
    start_link/0,
    register/2,
    unregister/1,
    find_handler/1,
    parse_topic_params/2,
    call_handler/3,
    list_handlers/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(TABLE, hornbeam_channel_handlers).

-record(handler, {
    pattern :: binary(),
    pattern_parts :: [binary()],
    param_names :: [binary()],
    module :: atom() | binary(),
    type :: python | erlang
}).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the channel registry.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register a handler for a topic pattern.
%% Pattern can include wildcards (*) which capture topic segments.
%% Example: "room:*" captures the room ID.
-spec register(binary(), map()) -> ok | {error, term()}.
register(Pattern, HandlerInfo) ->
    gen_server:call(?SERVER, {register, Pattern, HandlerInfo}).

%% @doc Unregister a handler for a topic pattern.
-spec unregister(binary()) -> ok.
unregister(Pattern) ->
    gen_server:call(?SERVER, {unregister, Pattern}).

%% @doc Find a handler for a specific topic.
%% Returns the first matching handler (exact matches take priority).
-spec find_handler(binary()) -> {ok, #handler{}} | {error, no_handler}.
find_handler(Topic) ->
    gen_server:call(?SERVER, {find_handler, Topic}).

%% @doc Parse topic parameters based on pattern.
%% Example: pattern "room:*", topic "room:123" returns a map with room_id => "123"
-spec parse_topic_params(#handler{}, binary()) -> map().
parse_topic_params(#handler{pattern_parts = PatternParts, param_names = ParamNames}, Topic) ->
    TopicParts = binary:split(Topic, <<":">>, [global]),
    parse_params(PatternParts, TopicParts, ParamNames, #{}).

%% @doc Call a handler function.
-spec call_handler(#handler{}, atom(), list()) -> term().
call_handler(#handler{type = python, module = Module}, Function, Args) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> 30000;
        T -> T
    end,
    case py:call(hornbeam_channels_runner, handle_call, [Module, Function, Args], #{}, TimeoutMs) of
        {ok, Result} -> Result;
        {error, Reason} -> {error, Reason}
    end;
call_handler(#handler{type = erlang, module = Module}, Function, Args) ->
    apply(Module, Function, Args).

%% @doc List all registered handlers.
-spec list_handlers() -> [{binary(), #handler{}}].
list_handlers() ->
    gen_server:call(?SERVER, list_handlers).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Create ETS table for handlers
    _ = ets:new(?TABLE, [named_table, protected, set, {keypos, 2}]),
    {ok, #{}}.

handle_call({register, Pattern, HandlerInfo}, _From, State) ->
    Handler = make_handler(Pattern, HandlerInfo),
    ets:insert(?TABLE, Handler),
    {reply, ok, State};

handle_call({unregister, Pattern}, _From, State) ->
    ets:delete(?TABLE, Pattern),
    {reply, ok, State};

handle_call({find_handler, Topic}, _From, State) ->
    Result = do_find_handler(Topic),
    {reply, Result, State};

handle_call(list_handlers, _From, State) ->
    Handlers = ets:tab2list(?TABLE),
    Result = [{H#handler.pattern, H} || H <- Handlers],
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

make_handler(Pattern, HandlerInfo) ->
    PatternParts = binary:split(Pattern, <<":">>, [global]),
    ParamNames = extract_param_names(PatternParts),
    Module = maps:get(module, HandlerInfo, maps:get(<<"module">>, HandlerInfo, undefined)),
    Type = maps:get(type, HandlerInfo, maps:get(<<"type">>, HandlerInfo, python)),
    #handler{
        pattern = Pattern,
        pattern_parts = PatternParts,
        param_names = ParamNames,
        module = Module,
        type = Type
    }.

%% Extract parameter names from pattern parts.
%% Wildcards are named based on the preceding part + "_id"
%% e.g., ["room", "*"] -> [<<"room_id">>]
%% e.g., ["chat", "*", "msg", "*"] -> [<<"chat_id">>, <<"msg_id">>]
extract_param_names(Parts) ->
    extract_param_names(Parts, undefined, []).

extract_param_names([], _PrevPart, Acc) ->
    lists:reverse(Acc);
extract_param_names([<<"*">> | Rest], undefined, Acc) ->
    %% Wildcard at start, use generic name
    extract_param_names(Rest, <<"*">>, [<<"id">> | Acc]);
extract_param_names([<<"*">> | Rest], PrevPart, Acc) ->
    %% Wildcard after a named part
    ParamName = <<PrevPart/binary, "_id">>,
    extract_param_names(Rest, <<"*">>, [ParamName | Acc]);
extract_param_names([Part | Rest], _PrevPart, Acc) ->
    extract_param_names(Rest, Part, Acc).

parse_params([], [], [], Params) ->
    Params;
parse_params([<<"*">> | PatternRest], [Value | TopicRest], [Name | NameRest], Params) ->
    parse_params(PatternRest, TopicRest, NameRest, Params#{Name => Value});
parse_params([_Part | PatternRest], [_Value | TopicRest], Names, Params) ->
    parse_params(PatternRest, TopicRest, Names, Params);
parse_params(_, _, _, Params) ->
    Params.

do_find_handler(Topic) ->
    TopicParts = binary:split(Topic, <<":">>, [global]),
    %% First try exact match
    case ets:lookup(?TABLE, Topic) of
        [Handler] ->
            {ok, Handler};
        [] ->
            %% Try pattern matching
            case find_matching_handler(TopicParts) of
                {ok, Handler} ->
                    {ok, Handler};
                {error, no_handler} ->
                    %% Try to find handler in Python
                    try_python_handler(Topic)
            end
    end.

%% Try to find a handler in Python for this topic
try_python_handler(Topic) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> 30000;
        T -> T
    end,
    case py:call(hornbeam_channels_runner, find_handler_for_topic, [Topic], #{}, TimeoutMs) of
        {ok, #{<<"pattern">> := Pattern, <<"module">> := Module, <<"type">> := Type}} ->
            %% Create and register handler directly in ETS (we're already in the gen_server)
            TypeAtom = case Type of
                <<"python">> -> python;
                <<"erlang">> -> erlang;
                _ -> python
            end,
            Handler = make_handler(Pattern, #{module => Module, type => TypeAtom}),
            ets:insert(?TABLE, Handler),
            {ok, Handler};
        {ok, none} ->
            {error, no_handler};
        {error, _} ->
            {error, no_handler}
    end.

find_matching_handler(TopicParts) ->
    %% Get all handlers and try to match
    Handlers = ets:tab2list(?TABLE),
    case find_first_match(Handlers, TopicParts) of
        {ok, Handler} -> {ok, Handler};
        none -> {error, no_handler}
    end.

find_first_match([], _TopicParts) ->
    none;
find_first_match([Handler | Rest], TopicParts) ->
    case matches_pattern(Handler#handler.pattern_parts, TopicParts) of
        true -> {ok, Handler};
        false -> find_first_match(Rest, TopicParts)
    end.

matches_pattern([], []) ->
    true;
matches_pattern([<<"*">> | PatternRest], [_Value | TopicRest]) ->
    matches_pattern(PatternRest, TopicRest);
matches_pattern([Part | PatternRest], [Part | TopicRest]) ->
    matches_pattern(PatternRest, TopicRest);
matches_pattern(_, _) ->
    false.
