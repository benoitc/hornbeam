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

-export([init/2]).
%% WebSocket callbacks (delegate to hornbeam_websocket)
-export([websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req, #{multi_app := true} = State) ->
    %% Multi-app mode: lookup mount based on request path
    Path = cowboy_req:path(Req),
    case hornbeam_mounts:lookup(Path) of
        {ok, Mount, PathInfo} ->
            %% Setup mount's pythonpath if specified
            setup_mount_pythonpath(Mount),
            %% Build new state from mount config
            NewState = State#{
                app_module => maps:get(app_module, Mount),
                app_callable => maps:get(app_callable, Mount),
                worker_class => maps:get(worker_class, Mount),
                timeout => maps:get(timeout, Mount),
                script_name => maps:get(prefix, Mount),
                path_info => PathInfo
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
            handle_asgi(Req, State)
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

        %% Build complete environ in Erlang
        Environ = build_wsgi_environ(Req, State),

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

        %% Call Python
        CtxRef = hornbeam_context_pool:get_context_ref(),
        case py_nif:context_call(CtxRef,
                <<"hornbeam_wsgi_worker">>, <<"handle_request">>,
                [self(), Buffer, AppModule, AppCallable, Environ], #{}) of
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

%% @private
%% Build environ map for WSGI
build_wsgi_environ(Req, State) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),
    {ClientIp, _ClientPort} = cowboy_req:peer(Req),

    %% Get SCRIPT_NAME and PATH_INFO from state (multi-app) or defaults
    ScriptName = maps:get(script_name, State, <<>>),
    PathInfo = maps:get(path_info, State, Path),

    %% Build HTTP_* headers
    HttpHeaders = maps:fold(fun(Name, Value, Acc) ->
        HeaderKey = header_to_wsgi_key(Name),
        Acc#{HeaderKey => Value}
    end, #{}, Headers),

    %% Build base environ
    BaseEnviron = #{
        <<"REQUEST_METHOD">> => Method,
        <<"SCRIPT_NAME">> => ScriptName,
        <<"PATH_INFO">> => PathInfo,
        <<"QUERY_STRING">> => Qs,
        <<"SERVER_NAME">> => Host,
        <<"SERVER_PORT">> => integer_to_binary(Port),
        <<"SERVER_PROTOCOL">> => format_protocol(Version),
        <<"REMOTE_ADDR">> => format_ip(ClientIp),
        <<"wsgi.url_scheme">> => Scheme
    },

    %% Merge HTTP headers
    Environ1 = maps:merge(BaseEnviron, HttpHeaders),

    %% Add CONTENT_TYPE and CONTENT_LENGTH if present
    ContentType = maps:get(<<"content-type">>, Headers, undefined),
    ContentLength = maps:get(<<"content-length">>, Headers, undefined),
    Environ2 = case ContentType of
        undefined -> Environ1;
        CT -> Environ1#{<<"CONTENT_TYPE">> => CT}
    end,
    case ContentLength of
        undefined -> Environ2;
        CL -> Environ2#{<<"CONTENT_LENGTH">> => CL}
    end.

%%% ============================================================================
%%% ASGI Handler - uses py_event_loop for full async
%%% ============================================================================

handle_asgi(Req, State) ->
    ReqInfo = build_request_info(Req),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),

        %% Build ASGI scope
        Scope = build_scope(Req, State),

        %% Read request body
        {ok, Body, _Req2} = cowboy_req:read_body(Req),

        %% Submit to event loop (non-blocking, async execution)
        %% Python will send response via erlang.send()
        _Ref = py_event_loop:create_task(
            <<"hornbeam_asgi_worker">>, <<"handle_asgi">>,
            [self(), AppModule, AppCallable, Scope, Body]),

        %% Receive response from async Python
        receive_asgi_response(Req, ReqInfo1, TimeoutMs, State)
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("ASGI handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            handle_error(Req, {Class, Reason}, ReqInfo1, State)
    end.

%% @private
%% Receive ASGI response from Python worker
receive_asgi_response(Req, ReqInfo, TimeoutMs, State) ->
    receive
        {<<"response">>, StatusCode, Headers, Body} ->
            %% Buffered response (single message)
            Response = #{
                <<"status">> => StatusCode,
                <<"headers">> => Headers,
                <<"body">> => Body
            },
            Response1 = hornbeam_http_hooks:run_on_response(Response),
            send_response(Req, Response1, State);
        {<<"headers">>, StatusCode, Headers} ->
            %% Streaming response
            CowboyHeaders = convert_headers(Headers),
            receive_asgi_body(Req, StatusCode, CowboyHeaders, TimeoutMs, State);
        {<<"early_hints">>, Headers} ->
            %% Early hints (103)
            HintHeaders = convert_headers(Headers),
            Req2 = cowboy_req:inform(103, HintHeaders, Req),
            receive_asgi_response(Req2, ReqInfo, TimeoutMs, State);
        {<<"error">>, Reason} ->
            handle_error(Req, Reason, ReqInfo, State)
    after TimeoutMs ->
        handle_error(Req, timeout, ReqInfo, State)
    end.

%% @private
receive_asgi_body(Req, StatusCode, CowboyHeaders, TimeoutMs, State) ->
    Req2 = cowboy_req:stream_reply(StatusCode, CowboyHeaders, Req),
    asgi_stream_body(Req2, TimeoutMs, State).

%% @private
%% Stream ASGI response body chunks to client
asgi_stream_body(Req, TimeoutMs, State) ->
    receive
        {<<"chunk">>, Chunk} ->
            ok = cowboy_req:stream_body(Chunk, nofin, Req),
            asgi_stream_body(Req, TimeoutMs, State);
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
%% Build ASGI scope
build_scope(Req, State) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),
    {ClientIp, ClientPort} = cowboy_req:peer(Req),

    %% Get root_path and path from state (multi-app) or defaults
    RootPath = maps:get(script_name, State, <<>>),
    ScopePath = maps:get(path_info, State, Path),

    HeaderList = maps:fold(fun(Name, Value, Acc) ->
        [[Name, Value] | Acc]
    end, [], Headers),

    LifespanState = hornbeam_lifespan:get_state(),

    #{
        type => <<"http">>,
        asgi => #{<<"version">> => <<"3.0">>, <<"spec_version">> => <<"2.4">>},
        http_version => format_http_version(Version),
        method => Method,
        scheme => Scheme,
        path => ScopePath,
        raw_path => ScopePath,
        query_string => Qs,
        root_path => RootPath,
        headers => HeaderList,
        server => {Host, Port},
        client => {format_ip(ClientIp), ClientPort},
        state => LifespanState,
        extensions => build_extensions(Version)
    }.

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
header_to_wsgi_key(Name) ->
    case Name of
        <<"content-type">> -> <<"CONTENT_TYPE">>;
        <<"content-length">> -> <<"CONTENT_LENGTH">>;
        _ ->
            Upper = string:uppercase(Name),
            Underscored = binary:replace(Upper, <<"-">>, <<"_">>, [global]),
            <<"HTTP_", Underscored/binary>>
    end.

%% @private
format_protocol('HTTP/1.0') -> <<"HTTP/1.0">>;
format_protocol('HTTP/1.1') -> <<"HTTP/1.1">>;
format_protocol('HTTP/2') -> <<"HTTP/2">>.

%% @private
format_http_version('HTTP/1.0') -> <<"1.0">>;
format_http_version('HTTP/1.1') -> <<"1.1">>;
format_http_version('HTTP/2') -> <<"2">>.

%% @private
format_ip({A, B, C, D}) ->
    list_to_binary([
        integer_to_list(A), $.,
        integer_to_list(B), $.,
        integer_to_list(C), $.,
        integer_to_list(D)
    ]);
format_ip(Addr = {_, _, _, _, _, _, _, _}) ->
    list_to_binary(inet:ntoa(Addr)).

%% @private
build_extensions('HTTP/2') ->
    #{
        <<"http.response.trailers">> => #{},
        <<"http.response.early_hints">> => #{}
    };
build_extensions(_) ->
    #{
        <<"http.response.early_hints">> => #{}
    }.

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
%%% Mount pythonpath setup
%%% ============================================================================

setup_mount_pythonpath(Mount) ->
    case maps:get(pythonpath, Mount, []) of
        [] ->
            ok;
        Paths when is_list(Paths) ->
            lists:foreach(fun(Path) ->
                PathBin = if
                    is_binary(Path) -> Path;
                    is_list(Path) -> list_to_binary(Path);
                    true -> Path
                end,
                py:eval(<<"__import__('sys').path.insert(0, p) if p not in __import__('sys').path else None">>,
                        #{p => PathBin})
            end, Paths)
    end.

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
