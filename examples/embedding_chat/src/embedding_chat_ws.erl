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

%%% @doc WebSocket echo handler using the ws_handler behaviour.
%%%
%%% Pure Erlang WebSocket handler that echoes messages.
%%% Demonstrates handling WebSocket in Erlang while HTTP is Python/FastAPI.
%%% Mounted through hornbeam's `routes' option; the route handler
%%% upgrades the request via livery_ws:upgrade/3.
-module(embedding_chat_ws).

-behaviour(ws_handler).

%% Route handler (HTTP side)
-export([handle/1]).
%% ws_handler callbacks
-export([init/2]).
-export([handle_in/2]).
-export([handle_info/2]).
-export([terminate/2]).

-record(state, {
    count = 0 :: non_neg_integer(),
    connected_at :: erlang:timestamp()
}).

%%% ============================================================================
%%% Route handler
%%% ============================================================================

handle(Req) ->
    livery_ws:upgrade(Req, ?MODULE, #{idle_timeout => 60000}).

%%% ============================================================================
%%% ws_handler callbacks
%%% ============================================================================

init(_Req, _Opts) ->
    State = #state{connected_at = os:timestamp()},
    Welcome = <<"Connected to Erlang WebSocket echo server!">>,
    {reply, {text, Welcome}, State}.

handle_in({text, Text}, #state{count = Count} = State) ->
    NewCount = Count + 1,
    Reply = iolist_to_binary([
        <<"[Erlang echo #">>,
        integer_to_binary(NewCount),
        <<"] ">>,
        Text
    ]),
    {reply, {text, Reply}, State#state{count = NewCount}};

handle_in({binary, Data}, #state{count = Count} = State) ->
    NewCount = Count + 1,
    {reply, {binary, Data}, State#state{count = NewCount}};

handle_in({ping, _Data}, State) ->
    %% ws auto-replies to pings before this callback
    {ok, State};

handle_in(_Frame, State) ->
    {ok, State}.

handle_info({send, Text}, State) when is_binary(Text) ->
    {reply, {text, Text}, State};

handle_info(close, State) ->
    {reply, {close, 1000, <<"Server closing">>}, State};

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, #state{count = Count, connected_at = ConnectedAt}) ->
    Duration = timer:now_diff(os:timestamp(), ConnectedAt) div 1000000,
    io:format("WebSocket closed: ~p messages in ~p seconds~n", [Count, Duration]),
    ok;
terminate(_Reason, _State) ->
    ok.
