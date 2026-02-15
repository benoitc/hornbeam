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

%%% @doc Pub/Sub messaging for Python apps.
%%%
%%% This module provides publish/subscribe messaging backed by Erlang's pg
%%% (process groups). It enables:
%%% - Real-time updates to web clients
%%% - Event broadcasting
%%% - Cross-node messaging (distributed pg)
%%%
%%% Note: This is primarily for Erlang-side subscriptions. For Python
%%% web handlers, use WebSocket connections with topic routing.
-module(hornbeam_pubsub).

-behaviour(gen_server).

-export([
    start_link/0,
    subscribe/1,
    subscribe/2,
    unsubscribe/1,
    unsubscribe/2,
    publish/2,
    get_members/1,
    get_local_members/1
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
-define(SCOPE, hornbeam_pubsub_scope).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Start the pubsub manager.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Subscribe the calling process to a topic.
-spec subscribe(Topic :: term()) -> ok.
subscribe(Topic) ->
    subscribe(Topic, self()).

%% @doc Subscribe a specific process to a topic.
-spec subscribe(Topic :: term(), Pid :: pid()) -> ok.
subscribe(Topic, Pid) ->
    pg:join(?SCOPE, Topic, Pid),
    ok.

%% @doc Unsubscribe the calling process from a topic.
-spec unsubscribe(Topic :: term()) -> ok.
unsubscribe(Topic) ->
    unsubscribe(Topic, self()).

%% @doc Unsubscribe a specific process from a topic.
-spec unsubscribe(Topic :: term(), Pid :: pid()) -> ok.
unsubscribe(Topic, Pid) ->
    pg:leave(?SCOPE, Topic, Pid),
    ok.

%% @doc Publish a message to all subscribers of a topic.
%% Returns the number of processes the message was sent to.
-spec publish(Topic :: term(), Message :: term()) -> non_neg_integer().
publish(Topic, Message) ->
    Members = pg:get_members(?SCOPE, Topic),
    lists:foreach(fun(Pid) ->
        Pid ! {pubsub, Topic, Message}
    end, Members),
    length(Members).

%% @doc Get all members subscribed to a topic (all nodes).
-spec get_members(Topic :: term()) -> [pid()].
get_members(Topic) ->
    pg:get_members(?SCOPE, Topic).

%% @doc Get local members subscribed to a topic.
-spec get_local_members(Topic :: term()) -> [pid()].
get_local_members(Topic) ->
    pg:get_local_members(?SCOPE, Topic).

%%% ============================================================================
%%% gen_server callbacks
%%% ============================================================================

init([]) ->
    %% Start pg scope for hornbeam pubsub
    %% pg:start returns {ok, Pid} or {error, {already_started, Pid}}
    case pg:start(?SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    {ok, #{}}.

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
