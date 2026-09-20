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

%%% @doc Livery HTTP handler for hornbeam.
%%%
%%% This module handles HTTP requests and routes them to either WSGI or ASGI
%%% handlers based on configuration.
%%%
%%% Architecture:
%%% - WSGI: Uses context_call with schedule_inline for yielding
%%% - ASGI: Uses py_event_loop for full async execution
%%% - Both stream responses via erlang.reply()/send()
%%%
%%% The request runs in its own livery request process; request-body
%%% chunks are pushed to that process as `{livery_body, Ref, _}' messages
%%% and Python response events arrive as plain messages, so a single
%%% selective receive drives both.
%%%
%%% @end
-module(hornbeam_handler).

-export([handle/1]).

%% Shared helpers used by hornbeam_asgi
-export([
    build_request_info/2,
    filter_hop_by_hop/1,
    convert_headers/1,
    parse_status_code/1,
    error_decision/2,
    get_content_length/1,
    to_binary/1
]).

%% Streaming threshold: bodies larger than this are streamed via the
%% receive loop while Python runs; smaller ones are read inline first.
-define(WSGI_STREAMING_THRESHOLD, 65536).  %% 64KB

%% Hop-by-hop headers that should not be forwarded
-define(HOP_BY_HOP_HEADERS, [
    <<"connection">>, <<"keep-alive">>, <<"proxy-authenticate">>,
    <<"proxy-authorization">>, <<"te">>, <<"trailers">>,
    <<"transfer-encoding">>, <<"upgrade">>
]).

-spec handle(livery_req:req()) -> livery_resp:resp().
handle(Req) ->
    State = case livery_req:config(Req) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end,
    dispatch(Req, State).

dispatch(Req, #{multi_app := true} = State) ->
    %% Multi-app mode: lookup mount based on request path
    Path = livery_req:path(Req),
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
            livery_resp:text(404, <<"Not Found">>)
    end;
dispatch(Req, State) ->
    %% Single-app mode (backward compatible)
    WorkerClass = maps:get(worker_class, State, wsgi),
    handle_request(WorkerClass, Req, State).

handle_request(wsgi, Req, State) ->
    handle_wsgi(Req, State);
handle_request(asgi, Req, State) ->
    %% Check for WebSocket upgrade
    case is_websocket_upgrade(Req) of
        true ->
            hornbeam_websocket:upgrade(Req, State);
        false ->
            hornbeam_asgi:handle(Req, State)
    end.

%% @private
is_websocket_upgrade(Req) ->
    case livery_req:header(<<"upgrade">>, Req) of
        undefined -> false;
        Upgrade ->
            string:lowercase(Upgrade) =:= <<"websocket">>
    end.

%%% ============================================================================
%%% WSGI Handler - unified channel-based approach with schedule_inline
%%% ============================================================================

handle_wsgi(Req, State) ->
    ReqInfo = build_request_info(Req, State),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),

        %% Build pre-parsed WSGI tuple (O(1) environ creation in Python)
        ReqTuple = hornbeam_request:build_wsgi_tuple(Req, State),

        %% Create buffer for request body (skip for bodyless requests).
        %% Small bodies are read inline; large ones stream into the
        %% buffer inside the receive loop while Python already runs.
        {Buffer, BodyCtx} = setup_body(Req, TimeoutMs),

        %% Call Python with tuple fast path
        CtxRef = hornbeam_context_pool:get_context_ref(),
        case py_nif:context_call(CtxRef,
                <<"hornbeam_wsgi_worker">>, <<"handle_request_tuple">>,
                [self(), Buffer, AppModule, AppCallable, ReqTuple], #{}) of
            {ok, <<"done">>} ->
                %% Resolve status/headers once Python replies
                livery_resp:stream_deferred(fun() ->
                    wsgi_wait(BodyCtx, ReqInfo1, TimeoutMs)
                end);
            {ok, <<"error">>} ->
                close_body(BodyCtx),
                error_resp(wsgi_error, ReqInfo1);
            {error, Reason} ->
                close_body(BodyCtx),
                error_resp(Reason, ReqInfo1)
        end
    catch
        Class:Error:Stack ->
            error_logger:error_msg("WSGI handler error: ~p:~p~n~p~n",
                                   [Class, Error, Stack]),
            error_resp({Class, Error}, ReqInfo1)
    end.

%% @private
%% Get content-length as integer, or undefined if not present/invalid
get_content_length(Req) ->
    case livery_req:header(<<"content-length">>, Req) of
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
%% Prepare the request-body buffer.
%% Returns {BufferArg, BodyCtx} where BufferArg is the Python-side
%% argument (`empty' or a py_buffer) and BodyCtx tracks whether body
%% chunks still stream into the buffer ({streaming, Ref, Buffer}) or the
%% buffer is complete (done).
setup_body(Req, TimeoutMs) ->
    Method = livery_req:method(Req),
    ContentLength = get_content_length(Req),
    case has_request_body(Method, ContentLength) of
        false ->
            {empty, done};
        true when is_integer(ContentLength),
                  ContentLength >= ?WSGI_STREAMING_THRESHOLD ->
            {ok, Buf} = py_buffer:new(ContentLength),
            case livery_req:body(Req) of
                {stream, Reader} ->
                    {Buf, {streaming, livery_body:ref(Reader), Buf}};
                {buffered, Data} ->
                    _ = py_buffer:write(Buf, iolist_to_binary(Data)),
                    _ = py_buffer:close(Buf),
                    {Buf, done};
                empty ->
                    _ = py_buffer:close(Buf),
                    {Buf, done}
            end;
        true ->
            {ok, Buf} = create_body_buffer(ContentLength),
            case livery_req:body(Req) of
                {stream, Reader} ->
                    case livery_body:read_all(Reader, TimeoutMs, infinity) of
                        {ok, Body, _Reader1} ->
                            _ = py_buffer:write(Buf, Body),
                            _ = py_buffer:close(Buf);
                        {error, Reason, _Reader1} ->
                            _ = py_buffer:close(Buf),
                            throw({body_read_error, Reason})
                    end;
                {buffered, Data} ->
                    _ = py_buffer:write(Buf, iolist_to_binary(Data)),
                    _ = py_buffer:close(Buf);
                empty ->
                    _ = py_buffer:close(Buf)
            end,
            {Buf, done}
    end.

%% @private
%% Create buffer for body - pre-allocate if content-length known
create_body_buffer(ContentLength) when is_integer(ContentLength), ContentLength > 0 ->
    py_buffer:new(ContentLength);
create_body_buffer(_) ->
    py_buffer:new().

%% @private
close_body({streaming, _Ref, Buffer}) ->
    _ = py_buffer:close(Buffer),
    ok;
close_body(done) ->
    ok.

%% @private
%% Wait for the Python response while pumping request-body chunks into
%% the buffer. Runs as a stream_deferred resolver: returns the response
%% decision before any header is written.
wsgi_wait(BodyCtx, ReqInfo, TimeoutMs) ->
    {BodyRef, Buffer} = body_ctx_ref(BodyCtx),
    receive
        {livery_body, BodyRef, {data, Chunk}} ->
            _ = py_buffer:write(Buffer, Chunk),
            wsgi_wait(BodyCtx, ReqInfo, TimeoutMs);
        {livery_body, BodyRef, _EofOrError} ->
            %% eof/trailers/reset/error all complete the buffer; a reset
            %% surfaces to Python as EOF on the body stream
            _ = py_buffer:close(Buffer),
            wsgi_wait(done, ReqInfo, TimeoutMs);
        {<<"start_response">>, StatusCode, Headers} ->
            %% Streaming response - filter hop-by-hop and start streaming
            SafeHeaders = convert_headers(filter_hop_by_hop(Headers)),
            {stream, parse_status_code(StatusCode), SafeHeaders,
             fun(Emit) -> wsgi_stream_loop(Emit, BodyCtx, TimeoutMs) end};
        {<<"response">>, StatusCode, Headers, Body} ->
            %% Complete response
            SafeHeaders = filter_hop_by_hop(Headers),
            Response = #{
                <<"status">> => StatusCode,
                <<"headers">> => SafeHeaders,
                <<"body">> => Body
            },
            Response1 = hornbeam_http_hooks:run_on_response(Response),
            close_body(BodyCtx),
            {full,
             parse_status_code(maps:get(<<"status">>, Response1)),
             convert_headers(maps:get(<<"headers">>, Response1)),
             maps:get(<<"body">>, Response1)};
        {<<"error">>, Reason} ->
            close_body(BodyCtx),
            error_decision(Reason, ReqInfo)
    after TimeoutMs ->
        close_body(BodyCtx),
        error_decision(timeout, ReqInfo)
    end.

%% @private
%% Receive and stream response chunks to the client while still pumping
%% any remaining request-body chunks into the buffer
wsgi_stream_loop(Emit, BodyCtx, TimeoutMs) ->
    {BodyRef, Buffer} = body_ctx_ref(BodyCtx),
    receive
        {livery_body, BodyRef, {data, Chunk}} ->
            _ = py_buffer:write(Buffer, Chunk),
            wsgi_stream_loop(Emit, BodyCtx, TimeoutMs);
        {livery_body, BodyRef, _EofOrError} ->
            _ = py_buffer:close(Buffer),
            wsgi_stream_loop(Emit, done, TimeoutMs);
        {<<"chunk">>, Chunk} ->
            case Emit(Chunk) of
                ok ->
                    wsgi_stream_loop(Emit, BodyCtx, TimeoutMs);
                {error, _} ->
                    %% The stream takes no more data: the client is gone, or
                    %% it rejects a body outright - an h2/h3 response to HEAD
                    %% answers `{error, invalid_stream_state}' where HTTP/1.1
                    %% just swallows the bytes. Unblock Python's body reads
                    %% and stop either way.
                    close_body(BodyCtx),
                    {error, closed}
            end;
        <<"done">> ->
            close_body(BodyCtx),
            ok;
        {<<"error">>, _Reason} ->
            close_body(BodyCtx),
            ok
    after TimeoutMs ->
        close_body(BodyCtx),
        ok
    end.

%% @private
body_ctx_ref({streaming, Ref, Buffer}) -> {Ref, Buffer};
body_ctx_ref(done) -> {make_ref(), undefined}.

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
%%% Error handling
%%% ============================================================================

%% @private
%% Full error response as a livery_resp (pre-stream errors)
error_resp(Error, ReqInfo) ->
    {full, StatusCode, Headers, Body} = error_decision(Error, ReqInfo),
    livery_resp:new(StatusCode, Headers, {full, Body}).

%% @doc Error response as a stream_deferred decision.
error_decision(Error, ReqInfo) ->
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Error, ReqInfo),
    {full, StatusCode, [{<<"content-type">>, <<"text/plain">>}], Body}.

%% @doc Request info map passed to HTTP hooks.
build_request_info(Req, State) ->
    {Host, Port} = hornbeam_request:server_info(Req, State),
    #{
        method => livery_req:method(Req),
        path => livery_req:path(Req),
        query_string => livery_req:query(Req),
        headers => headers_map(livery_req:headers(Req)),
        host => Host,
        port => Port,
        scheme => hornbeam_request:scheme(State),
        peer => livery_req:peer(Req)
    }.

%% @private
%% Hooks historically saw headers as a lowercase-keyed map; join
%% duplicates with ", " to preserve every value.
headers_map(Headers) ->
    lists:foldl(fun({Name, Value}, Acc) ->
        case Acc of
            #{Name := Prev} -> Acc#{Name := <<Prev/binary, ", ", Value/binary>>};
            _ -> Acc#{Name => Value}
        end
    end, #{}, Headers).

%%% ============================================================================
%%% Utilities
%%% ============================================================================

%% @doc Convert Python response headers ([[Name, Value], ...] or
%% [{Name, Value}, ...]) to livery's list shape, lowercasing names and
%% preserving duplicates.
convert_headers(Headers) ->
    lists:filtermap(fun(Header) ->
        case Header of
            [Name, Value] ->
                {true, {to_lower_binary(Name), to_binary(Value)}};
            {Name, Value} ->
                {true, {to_lower_binary(Name), to_binary(Value)}};
            _ ->
                false
        end
    end, Headers).

parse_status_code(Status) when is_binary(Status) ->
    case binary:split(Status, <<" ">>) of
        [CodeBin | _] -> binary_to_integer(CodeBin);
        _ -> 500
    end;
parse_status_code(Status) when is_list(Status) ->
    parse_status_code(list_to_binary(Status));
parse_status_code(Status) when is_integer(Status) ->
    Status.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_lower_binary(V) when is_binary(V) -> string:lowercase(V);
to_lower_binary(V) when is_list(V) -> string:lowercase(list_to_binary(V));
to_lower_binary(V) when is_atom(V) -> string:lowercase(atom_to_binary(V, utf8));
to_lower_binary(V) -> string:lowercase(to_binary(V)).
