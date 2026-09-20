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

%%% @doc Request data structure builder for WSGI/ASGI performance optimization.
%%%
%%% This module pre-parses HTTP requests in Erlang to minimize Python-side
%%% processing. Headers are pre-converted to WSGI HTTP_* format so Python
%%% only needs to do dict.update() without loops.
%%%
%%% Key optimizations:
%%% - Headers pre-converted to WSGI format (HTTP_ACCEPT_ENCODING, etc.)
%%% - Content-Type and Content-Length extracted separately
%%% - All string conversions done in Erlang (native binary operations)
%%% - Single tuple passed to Python for minimal marshalling overhead
-module(hornbeam_request).

-export([build_wsgi_tuple/2, build_asgi_scope/2]).
-export([to_wsgi_header_key/1, format_ip/1, format_http_version/1]).
-export([server_info/2, peer_info/1, scheme/1]).

%% @doc Build a pre-parsed WSGI request tuple for Python.
%%
%% Returns a tuple with all values pre-converted for WSGI:
%% {Method, ScriptName, PathInfo, QueryString, WsgiHeaders,
%%  ContentType, ContentLength, Body, Server, Client, Scheme, Protocol, State}
%%
%% WsgiHeaders is a map with HTTP_* keys already formatted.
-spec build_wsgi_tuple(livery_req:req(), map()) -> tuple().
build_wsgi_tuple(Req, State) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    Qs = livery_req:query(Req),
    Headers = livery_req:headers(Req),
    Scheme = scheme(State),
    {Host, Port} = server_info(Req, State),
    {ClientIp, ClientPort} = peer_info(Req),

    %% Get SCRIPT_NAME and PATH_INFO from state (multi-app) or defaults
    ScriptName = maps:get(script_name, State, <<>>),
    PathInfo = maps:get(path_info, State, Path),

    %% Convert headers to WSGI format with Content-Type/Length extracted
    {WsgiHeaders, ContentType, ContentLength} = convert_headers_wsgi(Headers),

    %% Get lifespan state
    LifespanState = hornbeam_lifespan:get_state(),

    {
        Method,                              % REQUEST_METHOD
        ScriptName,                          % SCRIPT_NAME
        PathInfo,                            % PATH_INFO
        Qs,                                  % QUERY_STRING
        WsgiHeaders,                         % HTTP_* headers (pre-converted map)
        ContentType,                         % CONTENT_TYPE (or undefined)
        ContentLength,                       % CONTENT_LENGTH (or undefined)
        undefined,                           % Body placeholder (passed via buffer)
        {Host, Port},                        % SERVER_NAME, SERVER_PORT
        {ClientIp, ClientPort},              % REMOTE_ADDR, REMOTE_PORT
        Scheme,                              % wsgi.url_scheme
        format_protocol(livery_req:protocol(Req)), % SERVER_PROTOCOL
        LifespanState                        % Lifespan state
    }.

%% @doc Build an optimized ASGI scope map.
%%
%% Headers are pre-formatted as [[name, value], ...] list.
%% All binary conversions done in Erlang.
%% Handles mount_id and per-mount lifespan state for multi-app mode.
-spec build_asgi_scope(livery_req:req(), map()) -> map().
build_asgi_scope(Req, State) ->
    Path = livery_req:path(Req),
    Protocol = livery_req:protocol(Req),
    {Host, Port} = server_info(Req, State),

    %% Get root_path and path from state (multi-app) or defaults
    RootPath = maps:get(script_name, State, <<>>),
    ScopePath = maps:get(path_info, State, Path),

    %% Convert headers to ASGI format [[name, value], ...] preserving
    %% duplicates and wire order
    HeaderList = [[Name, Value] || {Name, Value} <- livery_req:headers(Req)],

    %% Get mount_id for per-mount state isolation (multi-app mode)
    MountId = maps:get(mount_id, State, undefined),

    Client = peer_info(Req),

    %% Build scope map with all fields
    %% Note: state is NOT included here - Python fetches lazily via callback
    %% This avoids copying state dict on every request
    BaseScope = #{
        type => <<"http">>,
        asgi => #{<<"version">> => <<"3.0">>, <<"spec_version">> => <<"2.4">>},
        http_version => format_http_version(Protocol),
        method => livery_req:method(Req),
        scheme => scheme(State),
        path => ScopePath,
        raw_path => ScopePath,
        query_string => livery_req:query(Req),
        root_path => RootPath,
        headers => HeaderList,
        server => {Host, Port},
        client => Client,
        extensions => build_extensions(Protocol)
    },

    %% Add mount_id to scope if in multi-app mode (used by Python to get correct state)
    case MountId of
        undefined -> BaseScope;
        _ -> BaseScope#{mount_id => MountId}
    end.

%% @doc URL scheme for the listener that accepted the request.
%%
%% On HTTP/1.1 `livery_req:scheme/1' is always `<<"http">>' even under
%% TLS, so the listener transport recorded in the handler state is
%% authoritative.
-spec scheme(map()) -> binary().
scheme(State) ->
    maps:get(server_scheme, State, <<"http">>).

%% @doc Server host and port, from the host header (h1) or the
%% `:authority' pseudo-header (h2/h3), falling back to the bind port
%% recorded in the handler state.
-spec server_info(livery_req:req(), map()) -> {binary(), inet:port_number()}.
server_info(Req, State) ->
    Authority = case livery_req:header(<<"host">>, Req) of
        undefined ->
            case livery_req:authority(Req) of
                <<>> -> undefined;
                A -> A
            end;
        HostHeader ->
            HostHeader
    end,
    DefaultPort = maps:get(server_port, State, default_port(scheme(State))),
    case Authority of
        undefined ->
            {<<"localhost">>, DefaultPort};
        _ ->
            parse_authority(Authority, DefaultPort)
    end.

%% @doc Client address as `{IpBinary, Port}'.
%%
%% `livery_req:peer/1' is set on every adapter, but a synthetic request
%% (test adapter) may still carry none; degrade to an empty address so
%% the WSGI/ASGI shape stays stable.
-spec peer_info(livery_req:req()) -> {binary(), inet:port_number()}.
peer_info(Req) ->
    case livery_req:peer(Req) of
        undefined -> {<<>>, 0};
        {Ip, Port} -> {format_ip(Ip), Port}
    end.

%% @doc Convert header name to WSGI HTTP_* format.
%% Example: "accept-encoding" becomes "HTTP_ACCEPT_ENCODING"
-spec to_wsgi_header_key(binary()) -> binary().
to_wsgi_header_key(Name) ->
    Upper = to_upper_underscore(Name),
    <<"HTTP_", Upper/binary>>.

%% @doc Format IP address as binary string.
-spec format_ip(inet:ip_address()) -> binary().
format_ip({A, B, C, D}) ->
    iolist_to_binary([
        integer_to_list(A), $.,
        integer_to_list(B), $.,
        integer_to_list(C), $.,
        integer_to_list(D)
    ]);
format_ip(Addr = {_, _, _, _, _, _, _, _}) ->
    list_to_binary(inet:ntoa(Addr)).

%% @doc Format HTTP version for ASGI.
-spec format_http_version(h1 | h2 | h3) -> binary().
format_http_version(h1) -> <<"1.1">>;
format_http_version(h2) -> <<"2">>;
format_http_version(h3) -> <<"3">>.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

%% @private
%% Convert headers to WSGI format, extracting Content-Type and Content-Length.
%% Duplicate headers are joined with ", " per RFC 9110.
%% Returns {WsgiHeadersMap, ContentType, ContentLength}
convert_headers_wsgi(Headers) ->
    lists:foldl(fun({Name, Value}, {Acc, CT, CL}) ->
        case Name of
            <<"content-type">> ->
                {Acc, Value, CL};
            <<"content-length">> ->
                {Acc, CT, Value};
            _ ->
                Key = to_wsgi_header_key(Name),
                Acc1 = case Acc of
                    #{Key := Prev} -> Acc#{Key := <<Prev/binary, ", ", Value/binary>>};
                    _ -> Acc#{Key => Value}
                end,
                {Acc1, CT, CL}
        end
    end, {#{}, undefined, undefined}, Headers).

%% @private
%% Parse "Host[:Port]" including bracketed IPv6 "[::1]:8000".
parse_authority(<<"[", Rest/binary>> = Authority, DefaultPort) ->
    case binary:split(Rest, <<"]">>) of
        [Host, <<":", PortBin/binary>>] ->
            {<<"[", Host/binary, "]">>, to_port(PortBin, DefaultPort)};
        [Host, _] ->
            {<<"[", Host/binary, "]">>, DefaultPort};
        _ ->
            {Authority, DefaultPort}
    end;
parse_authority(Authority, DefaultPort) ->
    case binary:split(Authority, <<":">>) of
        [Host, PortBin] -> {Host, to_port(PortBin, DefaultPort)};
        [Host] -> {Host, DefaultPort}
    end.

%% @private
to_port(Bin, Default) ->
    try binary_to_integer(Bin)
    catch _:_ -> Default
    end.

%% @private
default_port(<<"https">>) -> 443;
default_port(_) -> 80.

%% @private
to_upper_underscore(Bin) ->
    << <<(upper_char(C))>> || <<C>> <= Bin >>.

upper_char(C) when C >= $a, C =< $z -> C - 32;
upper_char($-) -> $_;
upper_char(C) -> C.

%% @private
format_protocol(h1) -> <<"HTTP/1.1">>;
format_protocol(h2) -> <<"HTTP/2">>;
format_protocol(h3) -> <<"HTTP/3">>.

%% @private
%% Trailers are an h2/h3 feature. Early hints ride on livery's interim
%% responses, which h1 and h2 send and h3 does not (livery 0.7.0).
build_extensions(h1) ->
    #{<<"http.response.early_hints">> => #{}};
build_extensions(h2) ->
    #{<<"http.response.trailers">> => #{},
      <<"http.response.early_hints">> => #{}};
build_extensions(h3) ->
    #{<<"http.response.trailers">> => #{}}.
