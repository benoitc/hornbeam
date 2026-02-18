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

%%% @doc Cowboy WebSocket handler for ASGI applications.
%%%
%%% This module implements the Cowboy websocket behavior and bridges
%%% to ASGI WebSocket applications through the hornbeam_websocket_runner
%%% Python module.
%%%
%%% == ASGI WebSocket Protocol ==
%%%
%%% The handler translates between Cowboy WebSocket and ASGI WebSocket events:
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
-module(hornbeam_websocket).

-behaviour(cowboy_websocket).

-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

%% Pubsub API for Python
-export([
    subscribe/2,
    unsubscribe/2,
    publish/2,
    register_session/2,
    unregister_session/1
]).

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

%% @doc Initialize WebSocket connection.
%%
%% This is called during HTTP request handling to decide whether to
%% upgrade to WebSocket.
init(Req, _Opts) ->
    %% Build ASGI WebSocket scope
    Scope = build_websocket_scope(Req),

    %% Get app module and callable from config
    AppModule = hornbeam_config:get_config(app_module),
    AppCallable = hornbeam_config:get_config(app_callable),

    %% Generate session ID for this connection
    SessionId = generate_session_id(),

    State = #state{
        scope = Scope,
        app_module = AppModule,
        app_callable = AppCallable,
        session_id = SessionId
    },

    %% Get WebSocket options from config
    WsTimeout = hornbeam_config:get_config(websocket_timeout),
    WsMaxFrameSize = hornbeam_config:get_config(websocket_max_frame_size),
    WsCompress = hornbeam_config:get_config(websocket_compress, false),

    WsOpts = #{
        idle_timeout => get_value(WsTimeout, 60000),
        max_frame_size => get_value(WsMaxFrameSize, 16777216),
        compress => WsCompress
    },

    %% Upgrade to WebSocket
    {cowboy_websocket, Req, State, WsOpts}.

%% @doc WebSocket initialization after upgrade.
%%
%% Sends websocket.connect event to Python app.
websocket_init(#state{scope = Scope, app_module = AppModule,
                      app_callable = AppCallable, session_id = SessionId} = State) ->
    %% Register session
    register_session(SessionId, self()),

    %% Auto-subscribe to pubsub topic based on path (e.g., /chat/general -> chat:general)
    Path = maps:get(<<"path">>, Scope, <<>>),
    Topic = path_to_topic(Path),
    case Topic of
        undefined -> ok;
        _ -> hornbeam_pubsub:subscribe(Topic, self())
    end,

    %% Start Python WebSocket session
    case start_websocket_session(AppModule, AppCallable, Scope, SessionId) of
        {ok, Response} ->
            handle_connect_response(Response, State#state{subscriptions = [Topic]});
        {error, Reason} ->
            unregister_session(SessionId),
            error_logger:error_msg("WebSocket init error: ~p~n", [Reason]),
            {stop, State}
    end.

%% Convert URL path to pubsub topic: /chat/general -> <<"chat:general">>
path_to_topic(<<"/", Rest/binary>>) ->
    binary:replace(Rest, <<"/">>, <<":">>, [global]);
path_to_topic(_) ->
    undefined.

%% @doc Handle incoming WebSocket frames.
websocket_handle({text, Data}, #state{mode = undefined} = State) ->
    %% First message - detect protocol
    handle_first_message(text, Data, State);
websocket_handle({text, Data}, #state{mode = channel, channel_pid = Pid} = State) ->
    %% Channel protocol mode - route to channel process
    handle_channel_message(text, Data, Pid, State);
websocket_handle({text, Data}, #state{mode = asgi} = State) ->
    %% ASGI mode - standard handling
    handle_receive(text, Data, State);
websocket_handle({binary, Data}, #state{mode = undefined} = State) ->
    %% Binary data - assume ASGI mode
    State1 = State#state{mode = asgi},
    handle_receive(binary, Data, State1);
websocket_handle({binary, Data}, #state{mode = channel, channel_pid = Pid} = State) ->
    %% Channel protocol doesn't use binary, but forward anyway
    handle_channel_message(binary, Data, Pid, State);
websocket_handle({binary, Data}, #state{mode = asgi} = State) ->
    handle_receive(binary, Data, State);
websocket_handle(ping, State) ->
    %% Cowboy handles ping/pong automatically
    {ok, State};
websocket_handle(pong, State) ->
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

%% @doc Handle Erlang messages sent to the WebSocket process.
websocket_info({websocket_send, text, Data}, State) ->
    {[{text, Data}], State};
websocket_info({websocket_send, binary, Data}, State) ->
    {[{binary, Data}], State};
websocket_info({websocket_close, Code, Reason}, State) ->
    {[{close, Code, Reason}], State};
websocket_info({websocket_close, Code}, State) ->
    {[{close, Code, <<>>}], State};
%% Handle pubsub messages - forward to WebSocket as JSON (ASGI mode only)
websocket_info({pubsub, _Topic, Message}, #state{mode = asgi} = State) when is_map(Message) ->
    Json = json:encode(Message),
    {[{text, Json}], State};
websocket_info({pubsub, _Topic, Message}, #state{mode = asgi} = State) when is_binary(Message) ->
    {[{text, Message}], State};
websocket_info({pubsub, _Topic, _Message}, #state{mode = channel} = State) ->
    %% Channel mode handles pubsub through the channel process
    {ok, State};
%% Handle channel process death
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, #state{channel_pid = Pid} = State) ->
    %% Channel process died - close WebSocket
    {[{close, 1011, <<"Channel terminated">>}], State#state{channel_pid = undefined}};
websocket_info(_Info, State) ->
    {ok, State}.

%% @doc Handle WebSocket termination.
terminate(Reason, _Req, #state{session_id = SessionId,
                               app_module = AppModule,
                               app_callable = AppCallable,
                               mode = Mode,
                               channel_pid = ChannelPid} = _State) ->
    %% Unregister session from pubsub
    unregister_session(SessionId),
    %% Handle mode-specific cleanup
    case Mode of
        channel when is_pid(ChannelPid) ->
            %% Stop the channel process (it will handle cleanup)
            catch gen_server:stop(ChannelPid, normal, 5000);
        asgi ->
            %% Send disconnect event to Python ASGI app
            Code = reason_to_code(Reason),
            _ = send_disconnect(AppModule, AppCallable, SessionId, Code);
        _ ->
            ok
    end,
    ok;
terminate(_Reason, _Req, _State) ->
    %% Non-WebSocket request or request without proper state
    ok.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

build_websocket_scope(Req) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    RawPath = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),

    %% Get client info
    {ClientIp, ClientPort} = cowboy_req:peer(Req),

    %% Convert headers to list of [name, value] pairs
    HeaderList = maps:fold(fun(Name, Value, Acc) ->
        [[Name, Value] | Acc]
    end, [], Headers),

    %% Get WebSocket subprotocols from Sec-WebSocket-Protocol header
    Subprotocols = get_subprotocols(Headers),

    %% Determine WebSocket scheme
    WsScheme = case Scheme of
        <<"https">> -> <<"wss">>;
        _ -> <<"ws">>
    end,

    #{
        <<"type">> => <<"websocket">>,
        <<"asgi">> => #{
            <<"version">> => <<"3.0">>,
            <<"spec_version">> => <<"2.4">>
        },
        <<"http_version">> => format_http_version(Version),
        <<"method">> => Method,
        <<"scheme">> => WsScheme,
        <<"path">> => Path,
        <<"raw_path">> => RawPath,
        <<"query_string">> => Qs,
        <<"root_path">> => <<>>,
        <<"headers">> => HeaderList,
        <<"server">> => [Host, Port],
        <<"client">> => [format_ip(ClientIp), ClientPort],
        <<"subprotocols">> => Subprotocols
    }.

get_subprotocols(Headers) ->
    case maps:get(<<"sec-websocket-protocol">>, Headers, undefined) of
        undefined -> [];
        Protocols ->
            %% Parse comma-separated protocol list
            Parts = binary:split(Protocols, <<",">>, [global]),
            [string:trim(P) || P <- Parts]
    end.

format_http_version('HTTP/1.0') -> <<"1.0">>;
format_http_version('HTTP/1.1') -> <<"1.1">>;
format_http_version('HTTP/2') -> <<"2">>.

%% IPv4
format_ip({A, B, C, D}) ->
    iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A, B, C, D]));
%% IPv6
format_ip({A, B, C, D, E, F, G, H}) ->
    iolist_to_binary(io_lib:format("~.16B:~.16B:~.16B:~.16B:~.16B:~.16B:~.16B:~.16B",
                                   [A, B, C, D, E, F, G, H])).

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    Base64 = base64:encode(Bytes),
    %% Remove any + or / for URL safety
    binary:replace(binary:replace(Base64, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).

get_value(undefined, Default) -> Default;
get_value(Value, _Default) -> Value.

start_websocket_session(AppModule, AppCallable, Scope, SessionId) ->
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
            {[{close, Code, Reason}], State};
        _ ->
            %% Unknown response, close connection
            {[{close, 1002, <<"Protocol error">>}], State}
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
            {[{close, 1011, <<"Server error">>}], State}
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
        _ -> {Frames, State}
    end.

send_disconnect(AppModule, AppCallable, SessionId, Code) ->
    Timeout = hornbeam_config:get_config(timeout),
    TimeoutMs = case Timeout of
        undefined -> 5000;  % Shorter timeout for disconnect
        T -> min(T, 5000)
    end,
    catch py:call(hornbeam_websocket_runner, disconnect,
                  [AppModule, AppCallable, SessionId, Code], #{}, TimeoutMs).

reason_to_code(normal) -> 1000;
reason_to_code(shutdown) -> 1001;
reason_to_code(timeout) -> 1002;
reason_to_code(remote) -> 1000;
reason_to_code({remote, Code, _Reason}) -> Code;
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
            erlang:monitor(process, Pid),
            %% Route the initial message
            hornbeam_channel:handle_message(Pid, Message),
            {ok, State#state{mode = channel, channel_pid = Pid, accepted = true}};
        {error, Reason} ->
            error_logger:error_msg("Failed to start channel process: ~p~n", [Reason]),
            {[{close, 1011, <<"Server error">>}], State}
    end.

handle_channel_message(text, Data, Pid, State) ->
    case try_parse_channel_message(Data) of
        {ok, Message} ->
            hornbeam_channel:handle_message(Pid, Message),
            {ok, State};
        error ->
            %% Invalid JSON - close connection
            {[{close, 1007, <<"Invalid JSON">>}], State}
    end;
handle_channel_message(binary, _Data, _Pid, State) ->
    %% Channel protocol is text-only
    {ok, State}.

%%% ============================================================================
%%% Pubsub API for Python
%%% ============================================================================

-define(SESSION_TABLE, hornbeam_ws_sessions).

%% @doc Register a WebSocket session (called from websocket_init).
-spec register_session(binary(), pid()) -> ok.
register_session(SessionId, Pid) ->
    _ = ensure_session_table(),
    ets:insert(?SESSION_TABLE, {SessionId, Pid}),
    error_logger:info_msg("WS register: session=~p pid=~p~n", [SessionId, Pid]),
    ok.

%% @doc Unregister a WebSocket session.
-spec unregister_session(binary()) -> ok.
unregister_session(SessionId) ->
    catch ets:delete(?SESSION_TABLE, SessionId),
    ok.

%% @doc Subscribe a WebSocket session to a pubsub topic.
-spec subscribe(binary(), term()) -> ok | {error, session_not_found}.
subscribe(SessionId, Topic) ->
    error_logger:info_msg("WS subscribe: session=~p topic=~p~n", [SessionId, Topic]),
    case lookup_session(SessionId) of
        {ok, Pid} ->
            error_logger:info_msg("WS subscribe: found pid=~p~n", [Pid]),
            hornbeam_pubsub:subscribe(Topic, Pid),
            ok;
        error ->
            error_logger:warning_msg("WS subscribe: session not found~n"),
            {error, session_not_found}
    end.

%% @doc Unsubscribe a WebSocket session from a pubsub topic.
-spec unsubscribe(binary(), term()) -> ok.
unsubscribe(SessionId, Topic) ->
    case lookup_session(SessionId) of
        {ok, Pid} ->
            hornbeam_pubsub:unsubscribe(Topic, Pid),
            ok;
        error ->
            ok
    end.

%% @doc Publish a message to a topic (broadcasts to all subscribed WebSockets).
-spec publish(term(), term()) -> non_neg_integer().
publish(Topic, Message) ->
    Count = hornbeam_pubsub:publish(Topic, Message),
    error_logger:info_msg("WS publish: topic=~p count=~p~n", [Topic, Count]),
    Count.

%% @private
lookup_session(SessionId) ->
    _ = ensure_session_table(),
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, Pid}] -> {ok, Pid};
        [] -> error
    end.

%% @private
ensure_session_table() ->
    case ets:whereis(?SESSION_TABLE) of
        undefined ->
            ets:new(?SESSION_TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end.
