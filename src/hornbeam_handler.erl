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

%%% @doc Cowboy HTTP handler for hornbeam.
%%%
%%% This module handles HTTP requests and routes them to either WSGI or ASGI
%%% handlers based on configuration.
%%%
%%% Architecture:
%%% - WSGI: Uses context_call with schedule_inline for yielding
%%% - ASGI: Uses py_event_loop for full async execution
%%% - Both stream responses via erlang.reply()/send()
%%%
%%% @end
-module(hornbeam_handler).

-behaviour(cowboy_websocket).
-behaviour(cowboy_loop).

-export([init/2]).
%% Loop handler callback (for ASGI)
-export([info/3]).
%% WebSocket callbacks (delegate to hornbeam_websocket)
-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req, #{multi_app := true} = State) ->
    %% Multi-app mode: lookup mount based on request path
    Path = cowboy_req:path(Req),
    case hornbeam_mounts:lookup(Path) of
        {ok, Mount, PathInfo} ->
            %% pythonpath is setup at mount registration time (hornbeam_mounts.erl)
            %% Get mount_id for per-mount lifespan state isolation
            MountId = maps:get(mount_id, Mount),
            %% Build new state from mount config
            NewState = State#{
                app_module => maps:get(app_module, Mount),
                app_callable => maps:get(app_callable, Mount),
                worker_class => maps:get(worker_class, Mount),
                timeout => maps:get(timeout, Mount),
                script_name => maps:get(prefix, Mount),
                path_info => PathInfo,
                mount_id => MountId,
                %% Get per-mount lifespan state (not global)
                lifespan_state => hornbeam_lifespan:get_state(MountId)
            },
            WorkerClass = maps:get(worker_class, Mount),
            handle_request(WorkerClass, Req, NewState);
        {error, no_match} ->
            %% No mount matched - return 404
            Req2 = cowboy_req:reply(404,
                                    #{<<"content-type">> => <<"text/plain">>},
                                    <<"Not Found">>,
                                    Req),
            {ok, Req2, State}
    end;
init(Req, State) ->
    %% Single-app mode (backward compatible)
    WorkerClass = maps:get(worker_class, State, wsgi),
    handle_request(WorkerClass, Req, State).

handle_request(wsgi, Req, State) ->
    handle_wsgi(Req, State);
handle_request(asgi, Req, State) ->
    %% Check for WebSocket upgrade
    case is_websocket_upgrade(Req) of
        true ->
            handle_websocket_upgrade(Req, State);
        false ->
            hornbeam_asgi:init(Req, State)
    end.

%% @private
is_websocket_upgrade(Req) ->
    case cowboy_req:header(<<"upgrade">>, Req) of
        undefined -> false;
        Upgrade ->
            string:lowercase(Upgrade) =:= <<"websocket">>
    end.

%% @private
handle_websocket_upgrade(Req, State) ->
    %% Delegate to WebSocket handler
    hornbeam_websocket:init(Req, State).

%%% ============================================================================
%%% WSGI Handler - unified channel-based approach with schedule_inline
%%% ============================================================================

%% Streaming threshold: bodies larger than this are streamed via channel
-define(WSGI_STREAMING_THRESHOLD, 65536).  %% 64KB
-define(WSGI_BODY_CHUNK_SIZE, 65536).       %% 64KB chunks

%% Hop-by-hop headers that should not be forwarded
-define(HOP_BY_HOP_HEADERS, [
    <<"connection">>, <<"keep-alive">>, <<"proxy-authenticate">>,
    <<"proxy-authorization">>, <<"te">>, <<"trailers">>,
    <<"transfer-encoding">>, <<"upgrade">>
]).

handle_wsgi(Req, State) ->
    ReqInfo = build_request_info(Req),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),

        %% Build pre-parsed WSGI tuple (O(1) environ creation in Python)
        ReqTuple = hornbeam_request:build_wsgi_tuple(Req, State),

        %% Create buffer for request body (skip for bodyless requests)
        ContentLength = get_content_length(Req),
        Method = cowboy_req:method(Req),
        Buffer = case has_request_body(Method, ContentLength) of
            false ->
                %% No body expected - use empty buffer marker
                empty;
            true ->
                {ok, Buf} = create_body_buffer(ContentLength),
                write_body_to_buffer(Req, Buf, ContentLength),
                Buf
        end,

        %% Call Python with tuple fast path
        CtxRef = hornbeam_context_pool:get_context_ref(),
        case py_nif:context_call(CtxRef,
                <<"hornbeam_wsgi_worker">>, <<"handle_request_tuple">>,
                [self(), Buffer, AppModule, AppCallable, ReqTuple], #{}) of
            {ok, <<"done">>} ->
                %% Enter receive loop
                wsgi_receive_loop(Req, ReqInfo1, TimeoutMs, State);
            {ok, <<"error">>} ->
                handle_error(Req, wsgi_error, ReqInfo1, State);
            {error, Reason} ->
                handle_error(Req, Reason, ReqInfo1, State)
        end
    catch
        Class:Error:Stack ->
            error_logger:error_msg("WSGI handler error: ~p:~p~n~p~n",
                                   [Class, Error, Stack]),
            handle_error(Req, {Class, Error}, ReqInfo1, State)
    end.

%% @private
%% Get content-length as integer, or undefined if not present/invalid
get_content_length(Req) ->
    case cowboy_req:header(<<"content-length">>, Req) of
        undefined -> undefined;
        CLBin ->
            try binary_to_integer(CLBin)
            catch _:_ -> undefined
            end
    end.

%% @private
%% Check if request has a body (based on method and content-length)
has_request_body(<<"GET">>, undefined) -> false;
has_request_body(<<"HEAD">>, undefined) -> false;
has_request_body(<<"DELETE">>, undefined) -> false;
has_request_body(<<"OPTIONS">>, undefined) -> false;
has_request_body(_, 0) -> false;
has_request_body(_, _) -> true.

%% @private
%% Create buffer for body - pre-allocate if content-length known
create_body_buffer(undefined) ->
    py_buffer:new();
create_body_buffer(ContentLength) when is_integer(ContentLength), ContentLength > 0 ->
    py_buffer:new(ContentLength);
create_body_buffer(_) ->
    py_buffer:new().

%% @private
%% Write body to buffer - unified for small and large bodies
write_body_to_buffer(Req, Buffer, ContentLength) when
        ContentLength =:= undefined; ContentLength < ?WSGI_STREAMING_THRESHOLD ->
    %% Small body: read all, write once, close
    {ok, Body, _Req2} = cowboy_req:read_body(Req),
    py_buffer:write(Buffer, Body),
    py_buffer:close(Buffer);
write_body_to_buffer(Req, Buffer, _ContentLength) ->
    %% Large body: spawn process to stream chunks
    spawn_link(fun() -> stream_body_to_buffer(Req, Buffer, ?WSGI_BODY_CHUNK_SIZE) end).

%% @private
%% Stream request body to buffer in chunks
stream_body_to_buffer(Req, Buffer, ChunkSize) ->
    case cowboy_req:read_body(Req, #{length => ChunkSize}) of
        {ok, Chunk, _Req2} ->
            %% Last chunk
            py_buffer:write(Buffer, Chunk),
            py_buffer:close(Buffer);
        {more, Chunk, Req2} ->
            %% More data available
            py_buffer:write(Buffer, Chunk),
            stream_body_to_buffer(Req2, Buffer, ChunkSize)
    end.

%% @private
%% Main receive loop for WSGI responses from Python
wsgi_receive_loop(Req, ReqInfo, TimeoutMs, State) ->
    receive
        {<<"start_response">>, StatusCode, Headers} ->
            %% Streaming response - filter hop-by-hop and start streaming
            SafeHeaders = filter_hop_by_hop(Headers),
            CowboyHeaders = convert_headers(SafeHeaders),
            Req2 = cowboy_req:stream_reply(StatusCode, CowboyHeaders, Req),
            stream_response_loop(Req2, TimeoutMs, State);
        {<<"response">>, StatusCode, Headers, Body} ->
            %% Complete response
            SafeHeaders = filter_hop_by_hop(Headers),
            Response = #{
                <<"status">> => StatusCode,
                <<"headers">> => SafeHeaders,
                <<"body">> => Body
            },
            Response1 = hornbeam_http_hooks:run_on_response(Response),
            send_response(Req, Response1, State);
        {<<"error">>, Reason} ->
            handle_error(Req, Reason, ReqInfo, State)
    after TimeoutMs ->
        handle_error(Req, timeout, ReqInfo, State)
    end.

%% @private
%% Receive and stream response chunks to client
stream_response_loop(Req, TimeoutMs, State) ->
    receive
        {<<"chunk">>, Chunk} ->
            ok = cowboy_req:stream_body(Chunk, nofin, Req),
            stream_response_loop(Req, TimeoutMs, State);
        <<"done">> ->
            ok = cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State};
        {<<"error">>, _Reason} ->
            ok = cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State}
    after TimeoutMs ->
        ok = cowboy_req:stream_body(<<>>, fin, Req),
        {ok, Req, State}
    end.

%% @private
%% Filter hop-by-hop headers from response
filter_hop_by_hop(Headers) ->
    lists:filter(fun(Header) ->
        Name = case Header of
            [N, _] -> N;
            {N, _} -> N
        end,
        LowerName = string:lowercase(to_binary(Name)),
        not lists:member(LowerName, ?HOP_BY_HOP_HEADERS)
    end, Headers).

%%% ============================================================================
%%% Response sending
%%% ============================================================================

send_response(Req, Response, State) ->
    Status = maps:get(<<"status">>, Response),
    Headers = maps:get(<<"headers">>, Response),
    Body = maps:get(<<"body">>, Response),
    EarlyHints = maps:get(<<"early_hints">>, Response, []),

    %% Parse status code
    StatusCode = parse_status_code(Status),

    %% Convert headers to cowboy format
    CowboyHeaders = convert_headers(Headers),

    %% Send early hints if any (103 responses)
    Req1 = send_early_hints(Req, EarlyHints),

    %% Send response
    Req2 = cowboy_req:reply(StatusCode, CowboyHeaders, Body, Req1),
    {ok, Req2, State}.

%% @private
send_early_hints(Req, []) ->
    Req;
send_early_hints(Req, [Hints | Rest]) ->
    HintHeaders = convert_headers(Hints),
    Req1 = cowboy_req:inform(103, HintHeaders, Req),
    send_early_hints(Req1, Rest).

parse_status_code(Status) when is_binary(Status) ->
    case binary:split(Status, <<" ">>) of
        [CodeBin | _] -> binary_to_integer(CodeBin);
        _ -> 500
    end;
parse_status_code(Status) when is_list(Status) ->
    parse_status_code(list_to_binary(Status));
parse_status_code(Status) when is_integer(Status) ->
    Status.

%%% ============================================================================
%%% Error handling
%%% ============================================================================

handle_error(Req, Error, ReqInfo, State) ->
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Error, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body,
                            Req),
    {ok, Req2, State}.

%% @private
build_request_info(Req) ->
    #{
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        query_string => cowboy_req:qs(Req),
        headers => cowboy_req:headers(Req),
        host => cowboy_req:host(Req),
        port => cowboy_req:port(Req),
        scheme => cowboy_req:scheme(Req),
        peer => cowboy_req:peer(Req)
    }.

%%% ============================================================================
%%% Utilities
%%% ============================================================================

%% @private
convert_headers(Headers) ->
    lists:foldl(fun(Header, Acc) ->
        case Header of
            [Name, Value] ->
                Acc#{to_lower_binary(Name) => to_binary(Value)};
            {Name, Value} ->
                Acc#{to_lower_binary(Name) => to_binary(Value)};
            _ ->
                Acc
        end
    end, #{}, Headers).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_lower_binary(V) when is_binary(V) -> string:lowercase(V);
to_lower_binary(V) when is_list(V) -> string:lowercase(list_to_binary(V));
to_lower_binary(V) when is_atom(V) -> string:lowercase(atom_to_binary(V, utf8));
to_lower_binary(V) -> string:lowercase(to_binary(V)).

%%% ============================================================================
%%% Loop handler callback (for ASGI)
%%% ============================================================================

%% @private
%% Delegate to hornbeam_asgi for ASGI loop handler messages
info(Msg, Req, State) ->
    hornbeam_asgi:info(Msg, Req, State).

%%% ============================================================================
%%% WebSocket callbacks (delegate to hornbeam_websocket)
%%% ============================================================================

websocket_init(State) ->
    hornbeam_websocket:websocket_init(State).

websocket_handle(Frame, State) ->
    hornbeam_websocket:websocket_handle(Frame, State).

websocket_info(Info, State) ->
    hornbeam_websocket:websocket_info(Info, State).

terminate(Reason, Req, State) ->
    hornbeam_websocket:terminate(Reason, Req, State).
