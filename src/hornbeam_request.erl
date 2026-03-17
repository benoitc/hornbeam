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

%% @doc Build a pre-parsed WSGI request tuple for Python.
%%
%% Returns a tuple with all values pre-converted for WSGI:
%% {Method, ScriptName, PathInfo, QueryString, WsgiHeaders,
%%  ContentType, ContentLength, Body, Server, Client, Scheme, Protocol, State}
%%
%% WsgiHeaders is a map with HTTP_* keys already formatted.
-spec build_wsgi_tuple(cowboy_req:req(), map()) -> tuple().
build_wsgi_tuple(Req, State) ->
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),
    {ClientIp, ClientPort} = cowboy_req:peer(Req),

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
        {format_ip(ClientIp), ClientPort},   % REMOTE_ADDR, REMOTE_PORT
        Scheme,                              % wsgi.url_scheme
        format_protocol(Version),            % SERVER_PROTOCOL
        LifespanState                        % Lifespan state
    }.

%% @doc Build an optimized ASGI scope map.
%%
%% Headers are pre-formatted as [[name, value], ...] list.
%% All binary conversions done in Erlang.
-spec build_asgi_scope(cowboy_req:req(), map()) -> map().
build_asgi_scope(Req, State) ->
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

    %% Convert headers to ASGI format [[name, value], ...]
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

%% @doc Convert header name to WSGI HTTP_* format.
%% "accept-encoding" -> <<"HTTP_ACCEPT_ENCODING">>
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
-spec format_http_version(atom()) -> binary().
format_http_version('HTTP/1.0') -> <<"1.0">>;
format_http_version('HTTP/1.1') -> <<"1.1">>;
format_http_version('HTTP/2') -> <<"2">>.

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

%% @private
%% Convert headers to WSGI format, extracting Content-Type and Content-Length.
%% Returns {WsgiHeadersMap, ContentType, ContentLength}
convert_headers_wsgi(Headers) ->
    maps:fold(fun(Name, Value, {Acc, CT, CL}) ->
        case Name of
            <<"content-type">> ->
                {Acc, Value, CL};
            <<"content-length">> ->
                {Acc, CT, Value};
            _ ->
                Key = to_wsgi_header_key(Name),
                {Acc#{Key => Value}, CT, CL}
        end
    end, {#{}, undefined, undefined}, Headers).

%% @private
%% Convert lowercase header to uppercase with underscores.
%% "accept-encoding" -> <<"ACCEPT_ENCODING">>
to_upper_underscore(Bin) ->
    << <<(upper_char(C))>> || <<C>> <= Bin >>.

upper_char(C) when C >= $a, C =< $z -> C - 32;
upper_char($-) -> $_;
upper_char(C) -> C.

%% @private
format_protocol('HTTP/1.0') -> <<"HTTP/1.0">>;
format_protocol('HTTP/1.1') -> <<"HTTP/1.1">>;
format_protocol('HTTP/2') -> <<"HTTP/2">>.

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
