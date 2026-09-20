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

%%% @doc ASGI handler.
%%%
%%% Requests run in their own livery request process. The Python task is
%%% submitted to the event loop pool with this process's pid; response
%%% events (start_response/chunk/fin/error) arrive as plain messages,
%%% request-body chunks as `{livery_body, Ref, _}' messages, and client
%%% disconnects as `{livery_disconnect, Ref, Reason}' - all handled by
%%% one selective receive, first as a stream_deferred resolver (choosing
%%% status and headers) and then as the stream producer.
%%%
%%% @end
-module(hornbeam_asgi).

-export([handle/2]).

%% Threshold for passing the request body inline (64KB)
%% Bodies smaller than this are read synchronously and passed as a binary
-define(ASGI_BODY_BUFFER_THRESHOLD, 65536).

%%% ============================================================================
%%% Entry point (called from hornbeam_handler)
%%% ============================================================================

-spec handle(livery_req:req(), map()) -> livery_resp:resp().
handle(Req, HandlerState) ->
    ReqInfo = hornbeam_handler:build_request_info(Req, HandlerState),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    AppModule = maps:get(app_module, HandlerState),
    AppCallable = maps:get(app_callable, HandlerState),
    TimeoutMs = maps:get(timeout, HandlerState, 30000),

    %% Build ASGI scope
    Scope = hornbeam_request:build_asgi_scope(Req, HandlerState),

    %% Body exists if: Content-Length > 0, or Transfer-Encoding is present
    Method = livery_req:method(Req),
    ContentLength = hornbeam_handler:get_content_length(Req),
    TransferEncoding = livery_req:header(<<"transfer-encoding">>, Req),
    HasBody = has_request_body(Method, ContentLength, TransferEncoding),

    %% Small bodies with known Content-Length are read synchronously and
    %% passed directly; larger/streaming bodies flow through a byte
    %% channel fed by this process's receive loop
    {BodyArg, BodyRef} = case {HasBody, livery_req:body(Req)} of
        {false, _} ->
            {empty, undefined};
        {true, empty} ->
            {empty, undefined};
        {true, {buffered, Data}} ->
            {{body, iolist_to_binary(Data)}, undefined};
        {true, {stream, Reader}} when is_integer(ContentLength),
                                      ContentLength =< ?ASGI_BODY_BUFFER_THRESHOLD ->
            case livery_body:read_all(Reader, TimeoutMs, infinity) of
                {ok, Body, _Reader1} ->
                    {{body, Body}, undefined};
                {error, _Reason, _Reader1} ->
                    %% Truncated client body: hand Python what we have
                    {{body, <<>>}, undefined}
            end;
        {true, {stream, Reader}} ->
            {ok, Ch} = py_byte_channel:new(),
            {{channel, Ch}, livery_body:ref(Reader)}
    end,

    %% Submit task to event loop pool for parallel distribution
    {ok, LoopRef} = py_event_loop_pool:get_loop(),
    TaskRef = make_ref(),
    ok = py_nif:submit_task(LoopRef, self(), TaskRef,
        <<"hornbeam_asgi_worker">>, <<"handle_asgi">>,
        [self(), AppModule, AppCallable, Scope, BodyArg], #{}),

    St = #{
        req => Req,
        req_info => ReqInfo1,
        channel => body_channel(BodyArg),
        body_ref => BodyRef,
        timeout_ms => TimeoutMs
    },
    livery_resp:stream_deferred(fun() -> wait_response(St) end).

%%% ============================================================================
%%% Resolver: wait for the response head while pumping the request body
%%% ============================================================================

wait_response(#{req_info := ReqInfo, timeout_ms := TimeoutMs} = St) ->
    BodyRef = pump_ref(St),
    receive
        {livery_body, BodyRef, {data, Data}} ->
            ok = push_to_channel(maps:get(channel, St), Data),
            wait_response(St);
        {livery_body, BodyRef, _EofOrError} ->
            %% eof/trailers/reset/error all end the request body; a reset
            %% surfaces to Python as EOF on its body reads
            maybe_close_channel(maps:get(channel, St)),
            wait_response(St#{body_ref := undefined});
        {<<"start_response">>, StatusCode, Headers, FirstChunk} ->
            SafeHeaders = hornbeam_handler:convert_headers(
                hornbeam_handler:filter_hop_by_hop(Headers)),
            Status = hornbeam_handler:parse_status_code(StatusCode),
            {stream, Status, SafeHeaders,
             fun(Emit) -> stream_response(Emit, FirstChunk, St) end};
        {<<"early_hints">>, Headers} ->
            %% Best-effort: h3 (and HTTP/1.0 clients) have no interim
            %% responses, and livery answers {error, unsupported}
            _ = livery_req:inform(103, hornbeam_handler:convert_headers(Headers),
                                  maps:get(req, St)),
            wait_response(St);
        {<<"error">>, Reason} ->
            cleanup(St),
            hornbeam_handler:error_decision(Reason, ReqInfo);
        {async_result, _Ref, {ok, _}} ->
            wait_response(St);
        {async_result, _Ref, {error, Reason}} ->
            cleanup(St),
            hornbeam_handler:error_decision(Reason, ReqInfo);
        {livery_disconnect, _Ref, _Reason} ->
            %% Client gone before the response started; the emit of this
            %% decision fails on the closed stream, which livery treats
            %% as a peer disconnect
            cleanup(St),
            {full, 500, [], <<>>}
    after TimeoutMs ->
        cleanup(St),
        hornbeam_handler:error_decision(timeout, ReqInfo)
    end.

%%% ============================================================================
%%% Producer: stream chunks to the client
%%% ============================================================================

stream_response(Emit, FirstChunk, St) ->
    case hornbeam_handler:to_binary(FirstChunk) of
        <<>> ->
            stream_loop(Emit, St);
        Body ->
            case Emit(Body) of
                ok -> stream_loop(Emit, St);
                {error, _} -> stream_done(St)
            end
    end.

stream_loop(Emit, #{timeout_ms := TimeoutMs} = St) ->
    BodyRef = pump_ref(St),
    receive
        {livery_body, BodyRef, {data, Data}} ->
            ok = push_to_channel(maps:get(channel, St), Data),
            stream_loop(Emit, St);
        {livery_body, BodyRef, _EofOrError} ->
            maybe_close_channel(maps:get(channel, St)),
            stream_loop(Emit, St#{body_ref := undefined});
        {<<"chunk">>, Data} ->
            case Emit(hornbeam_handler:to_binary(Data)) of
                ok -> stream_loop(Emit, St);
                {error, _} -> stream_done(St)
            end;
        <<"fin">> ->
            cleanup(St),
            ok;
        {<<"early_hints">>, _} ->
            %% Too late: the final response head is already on the wire
            stream_loop(Emit, St);
        {<<"error">>, _Reason} ->
            %% Response already started: truncate the stream
            cleanup(St),
            ok;
        {async_result, _Ref, _} ->
            stream_loop(Emit, St);
        {livery_disconnect, _Ref, _Reason} ->
            stream_done(St)
    after TimeoutMs ->
        cleanup(St),
        ok
    end.

%% @private
%% Stop producing: the stream will take no more data. Either the client
%% disconnected, or the stream rejects a body at all - an h2/h3 response
%% to HEAD answers `{error, invalid_stream_state}' rather than swallowing
%% the bytes the way HTTP/1.1 does. Close the byte channel either way so
%% Python's body reads hit EOF (its sends to this pid are dropped once we
%% return).
stream_done(St) ->
    cleanup(St),
    {error, closed}.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

%% @private
%% Only pump raw body messages while a channel is live; otherwise use a
%% fresh ref that matches nothing.
pump_ref(#{body_ref := Ref}) when is_reference(Ref) -> Ref;
pump_ref(_) -> make_ref().

%% @private
body_channel({channel, Ch}) -> Ch;
body_channel(_) -> undefined.

%% @private
cleanup(St) ->
    maybe_close_channel(maps:get(channel, St)).

push_to_channel(Channel, Data) ->
    case py_byte_channel:send(Channel, Data) of
        ok -> ok;
        busy ->
            %% Channel full - wait a bit and retry
            timer:sleep(1),
            push_to_channel(Channel, Data);
        {error, closed} ->
            ok
    end.

maybe_close_channel(undefined) -> ok;
maybe_close_channel(Channel) ->
    try
        case py_byte_channel:info(Channel) of
            #{closed := true} -> ok;
            _ ->
                _ = py_byte_channel:close(Channel),
                ok
        end
    catch
        _:_ -> ok
    end.

%% @private
%% Check if request has a body based on method, content-length, and transfer-encoding
%% Per HTTP spec: body exists if Content-Length > 0 OR Transfer-Encoding is present
has_request_body(_, _, TE) when TE =/= undefined -> true;  %% Transfer-Encoding present
has_request_body(_, 0, _) -> false;                         %% Content-Length: 0
has_request_body(_, CL, _) when is_integer(CL), CL > 0 -> true;  %% Content-Length > 0
has_request_body(<<"GET">>, _, _) -> false;
has_request_body(<<"HEAD">>, _, _) -> false;
has_request_body(<<"DELETE">>, _, _) -> false;
has_request_body(<<"OPTIONS">>, _, _) -> false;
has_request_body(_, undefined, undefined) -> false.         %% No CL, no TE = no body
