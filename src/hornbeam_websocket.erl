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

-record(state, {
    scope :: map(),
    app_module :: binary(),
    app_callable :: binary(),
    session_id :: binary(),
    accepted = false :: boolean(),
    subprotocol :: binary() | undefined
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

    WsOpts = #{
        idle_timeout => get_value(WsTimeout, 60000),
        max_frame_size => get_value(WsMaxFrameSize, 16777216)
    },

    %% Upgrade to WebSocket
    {cowboy_websocket, Req, State, WsOpts}.

%% @doc WebSocket initialization after upgrade.
%%
%% Sends websocket.connect event to Python app.
websocket_init(#state{scope = Scope, app_module = AppModule,
                      app_callable = AppCallable, session_id = SessionId} = State) ->
    %% Start Python WebSocket session
    case start_websocket_session(AppModule, AppCallable, Scope, SessionId) of
        {ok, Response} ->
            handle_connect_response(Response, State);
        {error, Reason} ->
            error_logger:error_msg("WebSocket init error: ~p~n", [Reason]),
            {stop, State}
    end.

%% @doc Handle incoming WebSocket frames.
websocket_handle({text, Data}, State) ->
    handle_receive(text, Data, State);
websocket_handle({binary, Data}, State) ->
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
websocket_info(_Info, State) ->
    {ok, State}.

%% @doc Handle WebSocket termination.
terminate(Reason, _Req, #state{session_id = SessionId,
                               app_module = AppModule,
                               app_callable = AppCallable} = _State) ->
    %% Send disconnect event to Python
    Code = reason_to_code(Reason),
    _ = send_disconnect(AppModule, AppCallable, SessionId, Code),
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
format_http_version('HTTP/2') -> <<"2">>;
format_http_version(_) -> <<"1.1">>.

format_ip({A, B, C, D}) ->
    iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A, B, C, D]));
format_ip(Ip) when is_binary(Ip) ->
    Ip;
format_ip(Ip) when is_list(Ip) ->
    list_to_binary(Ip).

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
