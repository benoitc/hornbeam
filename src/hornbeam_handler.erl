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

init(Req, State) ->
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
                run_wsgi_optimized(Req, AppModule, AppCallable);
            Ctx ->
                %% Context affinity path - uses same worker as lifespan
                run_wsgi_with_context(Req, AppModule, AppCallable, Ctx, TimeoutMs)
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
run_wsgi_optimized(Req, AppModule, AppCallable) ->
    Environ = build_environ_for_nif(Req),
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
%% Context-aware fallback path using py:ctx_call
run_wsgi_with_context(Req, AppModule, AppCallable, PyContext, TimeoutMs) ->
    Environ = hornbeam_wsgi:build_environ(Req),
    py:ctx_call(PyContext, hornbeam_wsgi_runner, run_wsgi,
               [AppModule, AppCallable, Environ], #{}, TimeoutMs).

%% @private
%% Build environ dict for NIF optimization.
%% Uses binary keys which the NIF optimizes with interned strings.
build_environ_for_nif(Req) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),
    {ClientIp, _ClientPort} = cowboy_req:peer(Req),

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
        <<"SCRIPT_NAME">> => <<>>,
        <<"PATH_INFO">> => Path,
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
format_protocol('HTTP/2') -> <<"HTTP/2">>;
format_protocol(_) -> <<"HTTP/1.1">>.

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

        %% Check if context affinity is required (for module-level state sharing)
        %% Use optimized NIF path by default, fall back to ctx_call when needed
        UseContextAffinity = maps:get(context_affinity, State, false),
        PyContext = case UseContextAffinity of
            true -> hornbeam_lifespan:get_context();
            false -> undefined
        end,

        Result = case PyContext of
            undefined ->
                %% Optimized py_asgi:run/5 path (NIF-based marshalling)
                %% ~2x throughput vs py:call path
                run_asgi_optimized(Req, AppModule, AppCallable, ReqBody);
            Ctx ->
                %% Context affinity path - uses same worker as lifespan
                %% Required when app stores resources in module-level variables
                run_asgi_with_context(Req, AppModule, AppCallable, ReqBody, Ctx, TimeoutMs)
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
run_asgi_optimized(Req, AppModule, AppCallable, ReqBody) ->
    Scope = build_scope_for_nif(Req),
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
%% Context-aware fallback path using py:ctx_call
run_asgi_with_context(Req, AppModule, AppCallable, ReqBody, PyContext, TimeoutMs) ->
    Scope = hornbeam_asgi:build_scope(Req),
    py:ctx_call(PyContext, hornbeam_asgi_runner, run_asgi,
               [AppModule, AppCallable, Scope, ReqBody], #{}, TimeoutMs).

%% @private
%% Build scope with atom keys for NIF optimization.
%% The NIF uses asgi_get_key_for_term which optimizes atom key lookups.
build_scope_for_nif(Req) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),
    {ClientIp, ClientPort} = cowboy_req:peer(Req),

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
        path => Path,
        raw_path => Path,
        query_string => Qs,
        root_path => <<>>,
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

websocket_init(State) ->
    hornbeam_websocket:websocket_init(State).

websocket_handle(Frame, State) ->
    hornbeam_websocket:websocket_handle(Frame, State).

websocket_info(Info, State) ->
    hornbeam_websocket:websocket_info(Info, State).

terminate(Reason, Req, State) ->
    hornbeam_websocket:terminate(Reason, Req, State).
