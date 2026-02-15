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

%%% @doc WebSocket echo handler using cowboy_websocket.
%%%
%%% Pure Erlang WebSocket handler that echoes messages.
%%% Demonstrates handling WebSocket in Erlang while HTTP is Python/FastAPI.
-module(embedding_chat_ws).

-behaviour(cowboy_websocket).

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

-record(state, {
    count = 0 :: non_neg_integer(),
    connected_at :: erlang:timestamp()
}).

%%% ============================================================================
%%% Cowboy WebSocket callbacks
%%% ============================================================================

init(Req, Opts) ->
    {cowboy_websocket, Req, Opts, #{
        idle_timeout => 60000,
        max_frame_size => 65536
    }}.

websocket_init(_Opts) ->
    State = #state{connected_at = os:timestamp()},
    Welcome = <<"Connected to Erlang WebSocket echo server!">>,
    {[{text, Welcome}], State}.

websocket_handle({text, Text}, #state{count = Count} = State) ->
    NewCount = Count + 1,
    Reply = iolist_to_binary([
        <<"[Erlang echo #">>,
        integer_to_binary(NewCount),
        <<"] ">>,
        Text
    ]),
    {[{text, Reply}], State#state{count = NewCount}};

websocket_handle({binary, Data}, #state{count = Count} = State) ->
    NewCount = Count + 1,
    {[{binary, Data}], State#state{count = NewCount}};

websocket_handle({ping, Data}, State) ->
    {[{pong, Data}], State};

websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({send, Text}, State) when is_binary(Text) ->
    {[{text, Text}], State};

websocket_info(close, State) ->
    {[{close, 1000, <<"Server closing">>}], State};

websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #state{count = Count, connected_at = ConnectedAt}) ->
    Duration = timer:now_diff(os:timestamp(), ConnectedAt) div 1000000,
    io:format("WebSocket closed: ~p messages in ~p seconds~n", [Count, Duration]),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.
