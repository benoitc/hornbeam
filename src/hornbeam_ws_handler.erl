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

%%% @doc WebSocket session handler (ws_handler behaviour) for ASGI apps.
%%%
%%% Bridges the ws session to ASGI WebSocket applications through the
%%% hornbeam_websocket_runner Python module, or to Phoenix-style channels
%%% when the first text frame is a JSON array of 5 elements.
%%%
%%% == ASGI WebSocket Protocol ==
%%%
%%% Erlang -> Python (receive):
%%% - websocket.connect: On WebSocket upgrade
%%% - websocket.receive: On text/binary frame
%%% - websocket.disconnect: On close
%%%
%%% Python -> Erlang (send):
%%% - websocket.accept: Accept connection
%%% - websocket.send: Send text/binary frame
%%% - websocket.close: Close connection
-module(hornbeam_ws_handler).

-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

-record(state, {
    scope :: map(),
    app_module :: binary(),
    app_callable :: binary(),
    session_id :: binary(),
    accepted = false :: boolean(),
    subprotocol :: binary() | undefined,
    subscriptions = [] :: [term()],
    %% Channel protocol support
    mode = undefined :: undefined | asgi | channel,
    channel_pid :: pid() | undefined
}).

%% @doc Session start after a successful upgrade handshake.
%%
%% `Opts' comes from hornbeam_websocket:upgrade/2. The ws `Req' map
%% carries the socket peer, which the upgrade-time scope could not know.
init(Req, Opts) ->
    Scope0 = maps:get(scope, Opts),
    Scope = case maps:get(peer, Req, undefined) of
        {Ip, Port} ->
            Scope0#{<<"client">> => [hornbeam_request:format_ip(Ip), Port]};
        _ ->
            Scope0
    end,
    SessionId = maps:get(session_id, Opts),
    State = #state{
        scope = Scope,
        app_module = maps:get(app_module, Opts),
        app_callable = maps:get(app_callable, Opts),
        session_id = SessionId
    },

    %% Register session
    hornbeam_websocket:register_session(SessionId, self()),

    %% Auto-subscribe to pubsub topic based on path (e.g., /chat/general -> chat:general)
    Path = maps:get(<<"path">>, Scope, <<>>),
    Topic = path_to_topic(Path),
    case Topic of
        undefined -> ok;
        _ -> hornbeam_pubsub:subscribe(Topic, self())
    end,

    %% Start Python WebSocket session
    case start_websocket_session(State) of
        {ok, Response} ->
            handle_connect_response(Response, State#state{subscriptions = [Topic]});
        {error, Reason} ->
            hornbeam_websocket:unregister_session(SessionId),
            error_logger:error_msg("WebSocket init error: ~p~n", [Reason]),
            {stop, ws_init_failed, State}
    end.

%% Convert URL path to pubsub topic: /chat/general -> <<"chat:general">>
path_to_topic(<<"/", Rest/binary>>) ->
    binary:replace(Rest, <<"/">>, <<":">>, [global]);
path_to_topic(_) ->
    undefined.

%% @doc Handle incoming WebSocket frames.
handle_in({text, Data}, #state{mode = undefined} = State) ->
    %% First message - detect protocol
    handle_first_message(text, Data, State);
handle_in({text, Data}, #state{mode = channel, channel_pid = Pid} = State) ->
    %% Channel protocol mode - route to channel process
    handle_channel_message(text, Data, Pid, State);
handle_in({text, Data}, #state{mode = asgi} = State) ->
    %% ASGI mode - standard handling
    handle_receive(text, Data, State);
handle_in({binary, Data}, #state{mode = undefined} = State) ->
    %% Binary data - assume ASGI mode
    State1 = State#state{mode = asgi},
    handle_receive(binary, Data, State1);
handle_in({binary, Data}, #state{mode = channel, channel_pid = Pid} = State) ->
    %% Channel protocol doesn't use binary, but forward anyway
    handle_channel_message(binary, Data, Pid, State);
handle_in({binary, Data}, #state{mode = asgi} = State) ->
    handle_receive(binary, Data, State);
handle_in({ping, _}, State) ->
    %% ws_session already replied with a pong
    {ok, State};
handle_in({pong, _}, State) ->
    {ok, State};
handle_in(_Frame, State) ->
    {ok, State}.

%% @doc Handle Erlang messages sent to the WebSocket session process.
handle_info({websocket_send, text, Data}, State) ->
    {reply, {text, Data}, State};
handle_info({websocket_send, binary, Data}, State) ->
    {reply, {binary, Data}, State};
handle_info({websocket_close, Code, Reason}, State) ->
    {reply, {close, Code, Reason}, State};
handle_info({websocket_close, Code}, State) ->
    {reply, {close, Code, <<>>}, State};
%% Handle pubsub messages - forward to WebSocket as JSON (ASGI mode only)
handle_info({pubsub, _Topic, Message}, #state{mode = asgi} = State) when is_map(Message) ->
    Json = json:encode(Message),
    {reply, {text, Json}, State};
handle_info({pubsub, _Topic, Message}, #state{mode = asgi} = State) when is_binary(Message) ->
    {reply, {text, Message}, State};
handle_info({pubsub, _Topic, _Message}, #state{mode = channel} = State) ->
    %% Channel mode handles pubsub through the channel process
    {ok, State};
%% Handle channel process death
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{channel_pid = Pid} = State) ->
    %% Channel process died - close WebSocket
    {reply, {close, 1011, <<"Channel terminated">>}, State#state{channel_pid = undefined}};
handle_info(_Info, State) ->
    {ok, State}.

%% @doc Handle WebSocket termination.
terminate(Reason, #state{session_id = SessionId,
                         mode = Mode,
                         channel_pid = ChannelPid} = State) ->
    %% Unregister session from pubsub
    hornbeam_websocket:unregister_session(SessionId),
    %% Handle mode-specific cleanup
    _ = case Mode of
        channel when is_pid(ChannelPid) ->
            %% Stop the channel process (it will handle cleanup)
            _ = try gen_server:stop(ChannelPid, normal, 5000)
                catch _:_ -> ok
                end,
            ok;
        asgi ->
            %% Send disconnect event to Python ASGI app
            Code = reason_to_code(Reason),
            _ = send_disconnect(State, Code);
        _ ->
            ok
    end,
    ok;
terminate(_Reason, _State) ->
    %% Session torn down before init completed
    ok.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

start_websocket_session(#state{app_module = AppModule, app_callable = AppCallable,
                               scope = Scope, session_id = SessionId}) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> 30000;
        T -> T
    end,
    py:call(hornbeam_websocket_runner, start_session,
            [AppModule, AppCallable, Scope, SessionId], #{}, TimeoutMs).

handle_connect_response(Response, State) ->
    case maps:get(<<"type">>, Response, undefined) of
        <<"websocket.accept">> ->
            Subprotocol = maps:get(<<"subprotocol">>, Response, undefined),
            NewState = State#state{accepted = true, subprotocol = Subprotocol},
            %% Connection accepted, continue with WebSocket
            {ok, NewState};
        <<"websocket.close">> ->
            Code = maps:get(<<"code">>, Response, 1000),
            Reason = maps:get(<<"reason">>, Response, <<>>),
            {reply, {close, Code, Reason}, State};
        _ ->
            %% Unknown response, close connection
            {reply, {close, 1002, <<"Protocol error">>}, State}
    end.

handle_receive(Type, Data, #state{session_id = SessionId,
                                  app_module = AppModule,
                                  app_callable = AppCallable} = State) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> 30000;
        T -> T
    end,

    TypeStr = case Type of
        text -> <<"text">>;
        binary -> <<"bytes">>
    end,

    case py:call(hornbeam_websocket_runner, receive_message,
                 [AppModule, AppCallable, SessionId, TypeStr, Data], #{}, TimeoutMs) of
        {ok, Responses} when is_list(Responses) ->
            process_responses(Responses, State);
        {ok, Response} when is_map(Response) ->
            process_responses([Response], State);
        {error, Reason} ->
            error_logger:error_msg("WebSocket receive error: ~p~n", [Reason]),
            {reply, {close, 1011, <<"Server error">>}, State}
    end.

process_responses([], State) ->
    {ok, State};
process_responses(Responses, State) ->
    %% First, handle any broadcast requests
    lists:foreach(fun(Response) ->
        case maps:get(<<"type">>, Response, undefined) of
            <<"hornbeam.broadcast">> ->
                Topic = maps:get(<<"topic">>, Response),
                Message = maps:get(<<"message">>, Response),
                hornbeam_pubsub:publish(Topic, Message);
            _ ->
                ok
        end
    end, Responses),
    %% Then collect WebSocket frames to send
    Frames = lists:filtermap(fun(Response) ->
        case maps:get(<<"type">>, Response, undefined) of
            <<"websocket.send">> ->
                case maps:get(<<"text">>, Response, undefined) of
                    undefined ->
                        case maps:get(<<"bytes">>, Response, undefined) of
                            undefined -> false;
                            Bytes -> {true, {binary, Bytes}}
                        end;
                    Text -> {true, {text, Text}}
                end;
            <<"websocket.close">> ->
                Code = maps:get(<<"code">>, Response, 1000),
                Reason = maps:get(<<"reason">>, Response, <<>>),
                {true, {close, Code, Reason}};
            _ ->
                false
        end
    end, Responses),
    case Frames of
        [] -> {ok, State};
        _ -> {reply, Frames, State}
    end.

send_disconnect(#state{app_module = AppModule, app_callable = AppCallable,
                       session_id = SessionId}, Code) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> 5000;  % Shorter timeout for disconnect
        T -> min(T, 5000)
    end,
    try
        py:call(hornbeam_websocket_runner, disconnect,
                [AppModule, AppCallable, SessionId, Code], #{}, TimeoutMs)
    catch
        _:_ -> ok
    end.

%% The peer's own close code when it sent one (livery >= 0.7.0);
%% otherwise derived from the local terminate reason.
reason_to_code({remote, Code, _Reason}) when is_integer(Code) -> Code;
reason_to_code(remote) -> 1005;
reason_to_code(normal) -> 1000;
reason_to_code(shutdown) -> 1001;
reason_to_code(timeout) -> 1002;
reason_to_code({transport_error, _}) -> 1006;
reason_to_code(_) -> 1006.

%%% ============================================================================
%%% Channel Protocol Support
%%% ============================================================================

%% @doc Handle first message to detect protocol.
%% Channel protocol uses JSON arrays: [join_ref, ref, topic, event, payload]
handle_first_message(text, Data, State) ->
    case try_parse_channel_message(Data) of
        {ok, Message} when is_list(Message), length(Message) =:= 5 ->
            %% Detected channel protocol
            start_channel_mode(Message, State);
        _ ->
            %% Not channel protocol, use ASGI mode
            State1 = State#state{mode = asgi},
            handle_receive(text, Data, State1)
    end.

try_parse_channel_message(Data) ->
    try
        {ok, json:decode(Data)}
    catch
        _:_ -> error
    end.

start_channel_mode(Message, #state{session_id = SessionId} = State) ->
    %% Start channel process for this connection
    case hornbeam_channel:start_link(self(), SessionId) of
        {ok, Pid} ->
            %% Monitor the channel process
            _ = erlang:monitor(process, Pid),
            %% Route the initial message
            hornbeam_channel:handle_message(Pid, Message),
            {ok, State#state{mode = channel, channel_pid = Pid, accepted = true}};
        {error, Reason} ->
            error_logger:error_msg("Failed to start channel process: ~p~n", [Reason]),
            {reply, {close, 1011, <<"Server error">>}, State}
    end.

handle_channel_message(text, Data, Pid, State) ->
    case try_parse_channel_message(Data) of
        {ok, Message} ->
            hornbeam_channel:handle_message(Pid, Message),
            {ok, State};
        error ->
            %% Invalid JSON - close connection
            {reply, {close, 1007, <<"Invalid JSON">>}, State}
    end;
handle_channel_message(binary, _Data, _Pid, State) ->
    %% Channel protocol is text-only
    {ok, State}.
