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
%%% handlers based on configuration. It also handles WebSocket upgrades
%%% for ASGI applications.
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
    %% Check backend mode: nif (default), fd_reactor, or streaming
    case maps:get(backend_mode, State, nif) of
        fd_reactor ->
            handle_fd_reactor(Req, State);
        streaming ->
            handle_wsgi_streaming(Req, State);
        _ ->
            %% Check if streaming is enabled via config
            case maps:get(streaming, State, false) of
                true -> handle_wsgi_streaming(Req, State);
                false -> handle_wsgi(Req, State)
            end
    end;
handle_request(asgi, Req, State) ->
    %% Check for WebSocket upgrade
    case is_websocket_upgrade(Req) of
        true ->
            handle_websocket_upgrade(Req, State);
        false ->
            %% Check backend mode: nif (default), fd_reactor, or streaming
            case maps:get(backend_mode, State, nif) of
                fd_reactor ->
                    handle_fd_reactor(Req, State);
                streaming ->
                    handle_asgi_streaming(Req, State);
                _ ->
                    %% Check if streaming is enabled via config
                    case maps:get(streaming, State, false) of
                        true -> handle_asgi_streaming(Req, State);
                        false -> handle_asgi(Req, State)
                    end
            end
    end.

%%% ============================================================================
%%% FD Reactor Handler
%%% ============================================================================

%% @private
%% Handle request via FD reactor proxy bridge.
%% This path uses socketpair-based communication with Python reactor contexts,
%% providing streaming body handling and better GIL management.
handle_fd_reactor(Req, State) ->
    %% Build initial request map for hooks
    ReqInfo = build_request_info(Req),

    %% Run on_request hook
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        %% Delegate to proxy bridge
        hornbeam_proxy_bridge:handle(Req, State)
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("FD reactor handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            handle_error(Req, {Class, Reason}, ReqInfo1, State)
    end.

%% @private
is_websocket_upgrade(Req) ->
    case cowboy_req:header(<<"upgrade">>, Req) of
        undefined -> false;
        Upgrade ->
            string:lowercase(Upgrade) =:= <<"websocket">>
    end.

%%% ============================================================================
%%% Streaming Handlers
%%% ============================================================================

%% @private
%% Handle ASGI request with true response streaming.
%% Chunks are sent to client as they arrive from Python.
handle_asgi_streaming(Req, State) ->
    ReqInfo = build_request_info(Req),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),
        MaxPending = maps:get(stream_max_pending, State, 3),

        %% Read request body
        {ok, ReqBody, Req2} = cowboy_req:read_body(Req),

        %% Build ASGI scope
        Scope = build_scope_for_nif(Req, State),

        %% Call Python streaming runner with self() as handler_pid
        HandlerPid = self(),
        %% Submit to Python in a separate process so we can receive messages
        spawn_link(fun() ->
            Result = py:call(hornbeam_asgi_runner, run_asgi_streaming,
                            [AppModule, AppCallable, Scope, ReqBody, HandlerPid, MaxPending],
                            #{}, TimeoutMs),
            HandlerPid ! {python_done, Result}
        end),

        %% Wait for stream_start message
        AckTimeout = maps:get(stream_ack_timeout, State, 5000),
        receive
            {stream_start, Status, Headers} ->
                %% Start streaming response
                CowboyHeaders = convert_headers(Headers),
                Req3 = cowboy_req:stream_reply(Status, CowboyHeaders, Req2),
                %% Enter streaming loop
                stream_body_loop(Req3, State, AckTimeout);
            {stream_info, InfoStatus, InfoHeaders} ->
                %% Handle 1xx informational response first
                CowboyInfoHeaders = convert_headers(InfoHeaders),
                ok = cowboy_req:inform(InfoStatus, CowboyInfoHeaders, Req2),
                %% Continue waiting for stream_start (Req2 unchanged after inform)
                handle_asgi_streaming_continue(Req2, State, AckTimeout);
            {python_done, {error, Error}} ->
                handle_error(Req2, Error, ReqInfo1, State)
        after TimeoutMs ->
            handle_error(Req2, timeout, ReqInfo1, State)
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("ASGI streaming handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            handle_error(Req, {Class, Reason}, ReqInfo1, State)
    end.

%% @private
%% Continue waiting for stream_start after informational response
handle_asgi_streaming_continue(Req, State, AckTimeout) ->
    TimeoutMs = maps:get(timeout, State, 30000),
    receive
        {stream_start, Status, Headers} ->
            CowboyHeaders = convert_headers(Headers),
            Req2 = cowboy_req:stream_reply(Status, CowboyHeaders, Req),
            stream_body_loop(Req2, State, AckTimeout);
        {stream_info, InfoStatus, InfoHeaders} ->
            CowboyInfoHeaders = convert_headers(InfoHeaders),
            ok = cowboy_req:inform(InfoStatus, CowboyInfoHeaders, Req),
            handle_asgi_streaming_continue(Req, State, AckTimeout);
        {python_done, {error, Error}} ->
            ReqInfo = build_request_info(Req),
            handle_error(Req, Error, ReqInfo, State)
    after TimeoutMs ->
        ReqInfo = build_request_info(Req),
        handle_error(Req, timeout, ReqInfo, State)
    end.

%% @private
%% Handle WSGI request with true response streaming.
handle_wsgi_streaming(Req, State) ->
    ReqInfo = build_request_info(Req),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),
        MaxPending = maps:get(stream_max_pending, State, 3),

        %% Build environ
        Environ = build_environ_for_nif(Req, State),

        %% Call Python streaming runner with self() as handler_pid
        HandlerPid = self(),
        spawn_link(fun() ->
            Result = py:call(hornbeam_wsgi_runner, run_wsgi_streaming,
                            [AppModule, AppCallable, Environ, HandlerPid, MaxPending],
                            #{}, TimeoutMs),
            HandlerPid ! {python_done, Result}
        end),

        %% Wait for stream_start message
        AckTimeout = maps:get(stream_ack_timeout, State, 5000),
        receive
            {stream_start, Status, Headers} ->
                %% Parse WSGI status string
                StatusCode = parse_status_code(Status),
                CowboyHeaders = convert_headers(Headers),
                Req2 = cowboy_req:stream_reply(StatusCode, CowboyHeaders, Req),
                stream_body_loop(Req2, State, AckTimeout);
            {python_done, {error, Error}} ->
                handle_error(Req, Error, ReqInfo1, State)
        after TimeoutMs ->
            handle_error(Req, timeout, ReqInfo1, State)
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("WSGI streaming handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            handle_error(Req, {Class, Reason}, ReqInfo1, State)
    end.

%% @private
%% Streaming body loop - receives chunks from Python and forwards to client.
%% Sends acks back to Python for flow control.
stream_body_loop(Req, State, AckTimeout) ->
    TimeoutMs = maps:get(timeout, State, 30000),
    receive
        {stream_chunk, Chunk, false} ->
            %% Final chunk
            cowboy_req:stream_body(Chunk, fin, Req),
            %% Wait for python_done
            receive
                {python_done, _} -> ok
            after 1000 -> ok
            end,
            {ok, Req, State};
        {stream_chunk, Chunk, true} ->
            %% More chunks coming
            cowboy_req:stream_body(Chunk, nofin, Req),
            %% Send ack back to Python for flow control
            %% Note: The ack is implicit - Python's sender gets notified
            %% when erlang.send returns, so we continue receiving
            stream_body_loop(Req, State, AckTimeout);
        {stream_trailers, Trailers} ->
            %% HTTP/2 trailers
            CowboyTrailers = convert_headers(Trailers),
            cowboy_req:stream_trailers(CowboyTrailers, Req),
            stream_body_loop(Req, State, AckTimeout);
        {stream_file, FileFd} ->
            %% Sendfile optimization
            handle_sendfile(Req, FileFd, State);
        {python_done, _} ->
            %% Python finished (possibly early due to error)
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State}
    after TimeoutMs ->
        %% Timeout - close stream
        cowboy_req:stream_body(<<>>, fin, Req),
        {ok, Req, State}
    end.

%% @private
%% Handle sendfile for FileWrapper optimization
handle_sendfile(Req, FileFd, State) when is_integer(FileFd) ->
    %% Use cowboy_req:stream_body with sendfile
    %% Note: Cowboy doesn't directly support fd sendfile in stream mode,
    %% so we read and forward chunks
    case read_and_stream_file(Req, FileFd, 65536) of
        ok ->
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State};
        {error, _Reason} ->
            cowboy_req:stream_body(<<>>, fin, Req),
            {ok, Req, State}
    end.

%% @private
%% Read from file descriptor and stream to client
read_and_stream_file(Req, Fd, ChunkSize) ->
    case py_nif:fd_read(Fd, ChunkSize) of
        {ok, Data} when byte_size(Data) > 0 ->
            cowboy_req:stream_body(Data, nofin, Req),
            read_and_stream_file(Req, Fd, ChunkSize);
        {ok, <<>>} ->
            ok;
        {error, _} = Error ->
            Error
    end.

%% @private
handle_websocket_upgrade(Req, State) ->
    %% Delegate to WebSocket handler
    hornbeam_websocket:init(Req, State).

%%% ============================================================================
%%% WSGI Handler
%%% ============================================================================

handle_wsgi(Req, State) ->
    %% Build initial request map for hooks
    ReqInfo = build_request_info(Req),

    %% Run on_request hook
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        %% Get app module and callable from cached state (avoids ETS lookups)
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),

        %% Check if context affinity is required (for module-level state sharing)
        %% Use optimized NIF path by default, fall back to ctx_call when needed
        UseContextAffinity = maps:get(context_affinity, State, false),
        PyContext = case UseContextAffinity of
            true -> hornbeam_lifespan:get_context();
            false -> undefined
        end,

        Result = case PyContext of
            undefined ->
                %% Optimized py_wsgi:run/4 path (NIF-based marshalling)
                run_wsgi_optimized(Req, AppModule, AppCallable, State);
            Ctx ->
                %% Context affinity path - uses same worker as lifespan
                run_wsgi_with_context(Req, AppModule, AppCallable, Ctx, TimeoutMs, State)
        end,

        case Result of
            {ok, Response} ->
                %% Run on_response hook
                Response1 = hornbeam_http_hooks:run_on_response(Response),
                send_wsgi_response(Req, Response1, State);
            {error, {overloaded, Current, Max}} ->
                overload_response(Req, Current, Max, State);
            {error, Error} ->
                handle_error(Req, Error, ReqInfo1, State)
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("WSGI handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            handle_error(Req, {Class, Reason}, ReqInfo1, State)
    end.

%% @private
%% Optimized path using py_wsgi:run/4 with NIF marshalling
run_wsgi_optimized(Req, AppModule, AppCallable, State) ->
    Environ = build_environ_for_nif(Req, State),
    case py_wsgi:run(AppModule, AppCallable, Environ,
                     #{runner => <<"hornbeam_wsgi_runner">>}) of
        {ok, {Status, Headers, Body}} ->
            {ok, #{<<"status">> => Status,
                   <<"headers">> => Headers,
                   <<"body">> => Body}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% Fallback path using py:call (context routing is automatic)
run_wsgi_with_context(Req, AppModule, AppCallable, _PyContext, TimeoutMs, State) ->
    %% Build environ options from state (for multi-app mode)
    EnvOpts = case maps:get(script_name, State, undefined) of
        undefined -> #{};
        ScriptName -> #{script_name => ScriptName}
    end,
    Environ = hornbeam_wsgi:build_environ(Req, EnvOpts),
    %% Override PATH_INFO if set in state (from mount lookup)
    Environ1 = case maps:get(path_info, State, undefined) of
        undefined -> Environ;
        PathInfo -> Environ#{<<"PATH_INFO">> => PathInfo}
    end,
    py:call(hornbeam_wsgi_runner, run_wsgi,
           [AppModule, AppCallable, Environ1], #{}, TimeoutMs).

%% @private
%% Build environ dict for NIF optimization.
%% Uses binary keys which the NIF optimizes with interned strings.
%% State may contain script_name and path_info from mount lookup.
build_environ_for_nif(Req, State) ->
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

    %% Read body
    {ok, Body, _Req2} = cowboy_req:read_body(Req),

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
        <<"wsgi.version">> => {1, 0},
        <<"wsgi.url_scheme">> => Scheme,
        <<"wsgi.input">> => Body,
        <<"wsgi.multithread">> => true,
        <<"wsgi.multiprocess">> => true,
        <<"wsgi.run_once">> => false
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

%% @private
header_to_wsgi_key(Name) ->
    %% Convert header name to WSGI HTTP_* format
    %% e.g., "content-type" -> "CONTENT_TYPE" (but CONTENT_TYPE is special)
    %% "accept" -> "HTTP_ACCEPT"
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

send_wsgi_response(Req, Response, State) ->
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
    %% Convert hints to cowboy headers format
    HintHeaders = convert_headers(Hints),
    %% Send 103 Early Hints informational response
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
%%% ASGI Handler
%%% ============================================================================

handle_asgi(Req, State) ->
    %% Build initial request map for hooks
    ReqInfo = build_request_info(Req),

    %% Run on_request hook
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    try
        %% Get app module and callable from cached state (avoids ETS lookups)
        AppModule = maps:get(app_module, State),
        AppCallable = maps:get(app_callable, State),
        TimeoutMs = maps:get(timeout, State, 30000),

        %% Read request body
        {ok, ReqBody, Req2} = cowboy_req:read_body(Req),

        %% Determine ASGI execution mode:
        %% - context_affinity: Use lifespan context (for shared module state)
        %% - bind_context: Bind a fresh context per-request (reduces GIL overhead)
        %% - default: Use optimized NIF path (fastest for simple apps)
        UseContextAffinity = maps:get(context_affinity, State, false),
        BindContext = maps:get(bind_context, State, false),

        Result = case {UseContextAffinity, BindContext} of
            {true, _} ->
                %% Context affinity path - uses same worker as lifespan
                %% Required when app stores resources in module-level variables
                PyContext = hornbeam_lifespan:get_context(),
                run_asgi_with_context(Req, AppModule, AppCallable, ReqBody, PyContext, TimeoutMs, State);
            {false, true} ->
                %% Bound context path - binds worker for request duration
                %% Better for apps with multiple async operations
                run_asgi_bound(Req, AppModule, AppCallable, ReqBody, TimeoutMs, State);
            {false, false} ->
                %% Optimized py_asgi:run/5 path (NIF-based marshalling)
                %% Best for simple request/response apps
                run_asgi_optimized(Req, AppModule, AppCallable, ReqBody, State)
        end,

        case Result of
            {ok, Response} ->
                %% Run on_response hook
                Response1 = hornbeam_http_hooks:run_on_response(Response),
                send_asgi_response(Req2, Response1, State);
            {error, {overloaded, Current, Max}} ->
                overload_response(Req2, Current, Max, State);
            {error, Error} ->
                handle_error(Req2, Error, ReqInfo1, State)
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("ASGI handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            handle_error(Req, {Class, Reason}, ReqInfo1, State)
    end.

%% @private
%% Optimized path using py_asgi:run/5 with NIF marshalling
run_asgi_optimized(Req, AppModule, AppCallable, ReqBody, State) ->
    Scope = build_scope_for_nif(Req, State),
    case py_asgi:run(AppModule, AppCallable, Scope, ReqBody,
                     #{runner => <<"hornbeam_asgi_runner">>}) of
        {ok, {Status, Headers, Body}} ->
            {ok, #{<<"status">> => Status,
                   <<"headers">> => Headers,
                   <<"body">> => Body}};
        {error, _} = Error ->
            Error
    end.

%% @private
%% Fallback path using py:call (context routing is automatic)
run_asgi_with_context(Req, AppModule, AppCallable, ReqBody, _PyContext, TimeoutMs, State) ->
    %% Build scope options from state (for multi-app mode)
    ScopeOpts = case maps:get(script_name, State, undefined) of
        undefined -> #{};
        ScriptName -> #{root_path => ScriptName}
    end,
    Scope = hornbeam_asgi:build_scope(Req, ScopeOpts),
    %% Override path if set in state (from mount lookup)
    Scope1 = case maps:get(path_info, State, undefined) of
        undefined -> Scope;
        PathInfo -> Scope#{<<"path">> => PathInfo, <<"raw_path">> => PathInfo}
    end,
    py:call(hornbeam_asgi_runner, run_asgi,
           [AppModule, AppCallable, Scope1, ReqBody], #{}, TimeoutMs).

%% @private
%% Run ASGI with automatic context routing.
%% Context affinity is handled by the py_context_router automatically.
run_asgi_bound(Req, AppModule, AppCallable, ReqBody, TimeoutMs, State) ->
    %% Build scope options from state (for multi-app mode)
    ScopeOpts = case maps:get(script_name, State, undefined) of
        undefined -> #{};
        ScriptName -> #{root_path => ScriptName}
    end,
    Scope = hornbeam_asgi:build_scope(Req, ScopeOpts),
    %% Override path if set in state (from mount lookup)
    Scope1 = case maps:get(path_info, State, undefined) of
        undefined -> Scope;
        PathInfo -> Scope#{<<"path">> => PathInfo, <<"raw_path">> => PathInfo}
    end,
    py:call(hornbeam_asgi_runner, run_asgi,
           [AppModule, AppCallable, Scope1, ReqBody], #{}, TimeoutMs).

%% @private
%% Build scope with atom keys for NIF optimization.
%% The NIF uses asgi_get_key_for_term which optimizes atom key lookups.
%% State may contain script_name (root_path) and path_info from mount lookup.
build_scope_for_nif(Req, State) ->
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

send_asgi_response(Req, Response, State) ->
    Status = maps:get(<<"status">>, Response),
    Headers = maps:get(<<"headers">>, Response),
    Body = maps:get(<<"body">>, Response),
    EarlyHints = maps:get(<<"early_hints">>, Response, []),

    %% Convert status
    StatusCode = case Status of
        undefined -> 500;
        S when is_integer(S) -> S;
        S -> parse_status_code(S)
    end,

    %% Convert headers to cowboy format
    CowboyHeaders = convert_headers(Headers),

    %% Send early hints if any
    Req1 = send_early_hints(Req, EarlyHints),

    Req2 = cowboy_req:reply(StatusCode, CowboyHeaders, Body, Req1),
    {ok, Req2, State}.

%%% ============================================================================
%%% Error handling
%%% ============================================================================

%% @private
%% Handle errors using the on_error hook if configured
handle_error(Req, Error, ReqInfo, State) ->
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Error, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body,
                            Req),
    {ok, Req2, State}.

%% @private
%% Return 503 Service Unavailable when Python workers are overloaded
overload_response(Req, Current, Max, State) ->
    ErrorMsg = io_lib:format("Service temporarily unavailable: ~p/~p workers busy",
                             [Current, Max]),
    Req2 = cowboy_req:reply(503,
                            #{<<"content-type">> => <<"text/plain">>,
                              <<"retry-after">> => <<"1">>},
                            iolist_to_binary(ErrorMsg),
                            Req),
    {ok, Req2, State}.

%% @private
%% Build request info map for hooks
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
%% Convert headers from various formats to cowboy map format
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
%%% WebSocket callbacks (delegate to hornbeam_websocket)
%%% ============================================================================

%% @private
%% Setup pythonpath for a mount before executing the app.
%% This ensures mount-specific dependencies are available.
%% Note: paths are added at startup too, but this ensures they're
%% at the front of sys.path for this request.
setup_mount_pythonpath(Mount) ->
    case maps:get(pythonpath, Mount, []) of
        [] ->
            ok;
        Paths when is_list(Paths) ->
            %% Add each path to sys.path if not already present
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

websocket_init(State) ->
    hornbeam_websocket:websocket_init(State).

websocket_handle(Frame, State) ->
    hornbeam_websocket:websocket_handle(Frame, State).

websocket_info(Info, State) ->
    hornbeam_websocket:websocket_info(Info, State).

terminate(Reason, Req, State) ->
    hornbeam_websocket:terminate(Reason, Req, State).
