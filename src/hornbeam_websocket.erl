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

%%% @doc WebSocket upgrade and session registry.
%%%
%%% The HTTP-side entry point: builds the ASGI WebSocket scope and hands
%%% the request to the ws session via livery_ws:upgrade/3 with
%%% hornbeam_ws_handler as the session handler. Also owns the
%%% session-id -> pid ETS registry and the pubsub API exposed to Python.
-module(hornbeam_websocket).

-export([upgrade/2, build_websocket_scope/2]).

%% Pubsub API for Python
-export([
    subscribe/2,
    unsubscribe/2,
    publish/2,
    register_session/2,
    unregister_session/1
]).

%% @doc Upgrade an HTTP request to a WebSocket session.
%%
%% Returns the livery response produced by the handshake (101 taken_over
%% on success, 400/500 otherwise).
-spec upgrade(livery_req:req(), map()) -> livery_resp:resp().
upgrade(Req, State) ->
    Scope = build_websocket_scope(Req, State),

    %% Get app module and callable from config
    AppModule = hornbeam_config:get_config(app_module),
    AppCallable = hornbeam_config:get_config(app_callable),

    %% Generate session ID for this connection
    SessionId = generate_session_id(),

    WsTimeout = hornbeam_config:get_config(websocket_timeout),
    MaxFrameSize = hornbeam_config:get_config(websocket_max_frame_size),
    Compress = hornbeam_config:get_config(websocket_compress),

    %% Subprotocols are deliberately not passed: livery would reject
    %% clients whose offer does not intersect - negotiation happens in
    %% the Python app instead, as before
    Opts = #{
        scope => Scope,
        app_module => AppModule,
        app_callable => AppCallable,
        session_id => SessionId,
        idle_timeout => get_value(WsTimeout, 60000),
        max_frame_size => get_value(MaxFrameSize, 16777216),
        compress => get_value(Compress, false) =:= true
    },
    livery_ws:upgrade(Req, hornbeam_ws_handler, Opts).

%% @doc Build the ASGI WebSocket scope from a livery request.
%%
%% The client address is unknown at upgrade time; hornbeam_ws_handler
%% fills `<<"client">>' from the ws req map once the session starts.
-spec build_websocket_scope(livery_req:req(), map()) -> map().
build_websocket_scope(Req, State) ->
    Path = livery_req:path(Req),
    Headers = livery_req:headers(Req),
    {Host, Port} = hornbeam_request:server_info(Req, State),

    %% Convert headers to list of [name, value] pairs
    HeaderList = [[Name, Value] || {Name, Value} <- Headers],

    %% Get WebSocket subprotocols from Sec-WebSocket-Protocol header
    Subprotocols = get_subprotocols(Req),

    %% Determine WebSocket scheme from the listener transport
    WsScheme = case hornbeam_request:scheme(State) of
        <<"https">> -> <<"wss">>;
        _ -> <<"ws">>
    end,

    #{
        <<"type">> => <<"websocket">>,
        <<"asgi">> => #{
            <<"version">> => <<"3.0">>,
            <<"spec_version">> => <<"2.4">>
        },
        <<"http_version">> =>
            hornbeam_request:format_http_version(livery_req:protocol(Req)),
        <<"method">> => livery_req:method(Req),
        <<"scheme">> => WsScheme,
        <<"path">> => Path,
        <<"raw_path">> => Path,
        <<"query_string">> => livery_req:query(Req),
        <<"root_path">> => <<>>,
        <<"headers">> => HeaderList,
        <<"server">> => [Host, Port],
        <<"client">> => [<<>>, 0],
        <<"subprotocols">> => Subprotocols
    }.

get_subprotocols(Req) ->
    case livery_req:header(<<"sec-websocket-protocol">>, Req) of
        undefined -> [];
        Protocols ->
            %% Parse comma-separated protocol list
            Parts = binary:split(Protocols, <<",">>, [global]),
            [string:trim(P) || P <- Parts]
    end.

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    Base64 = base64:encode(Bytes),
    %% Remove any + or / for URL safety
    binary:replace(binary:replace(Base64, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).

get_value(undefined, Default) -> Default;
get_value(Value, _Default) -> Value.

%%% ============================================================================
%%% Pubsub API for Python
%%% ============================================================================

-define(SESSION_TABLE, hornbeam_ws_sessions).

%% @doc Register a WebSocket session (called from hornbeam_ws_handler).
-spec register_session(binary(), pid()) -> ok.
register_session(SessionId, Pid) ->
    _ = ensure_session_table(),
    ets:insert(?SESSION_TABLE, {SessionId, Pid}),
    error_logger:info_msg("WS register: session=~p pid=~p~n", [SessionId, Pid]),
    ok.

%% @doc Unregister a WebSocket session.
-spec unregister_session(binary()) -> ok.
unregister_session(SessionId) ->
    try ets:delete(?SESSION_TABLE, SessionId)
    catch _:_ -> true
    end,
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
