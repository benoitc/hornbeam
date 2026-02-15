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

%%% @doc WSGI environment builder and protocol handling.
%%%
%%% Builds a PEP 3333 compliant WSGI environ dictionary from a Cowboy request.
%%% This module creates environ dicts with all required and recommended WSGI
%%% variables for full PEP 3333 compliance.
%%%
%%% == Required CGI Variables ==
%%% - REQUEST_METHOD
%%% - SCRIPT_NAME
%%% - PATH_INFO
%%% - QUERY_STRING
%%% - CONTENT_TYPE (if present)
%%% - CONTENT_LENGTH (if present)
%%% - SERVER_NAME
%%% - SERVER_PORT
%%% - SERVER_PROTOCOL
%%% - HTTP_* (for each request header)
%%%
%%% == Required WSGI Variables ==
%%% - wsgi.version: (1, 0)
%%% - wsgi.url_scheme: "http" or "https"
%%% - wsgi.input: Request body
%%% - wsgi.errors: "stderr" (routed to logging in Python)
%%% - wsgi.multithread: true
%%% - wsgi.multiprocess: true
%%% - wsgi.run_once: false
%%%
%%% == Recommended Extensions ==
%%% - wsgi.file_wrapper: FileWrapper class
%%% - wsgi.input_terminated: true
%%% - wsgi.early_hints: callback function
%%%
%%% == Additional Variables ==
%%% - REMOTE_ADDR: Client IP address
%%% - REMOTE_PORT: Client port
%%% - REMOTE_HOST: Client hostname (if available)
-module(hornbeam_wsgi).

-export([
    build_environ/1,
    build_environ/2
]).

-type environ_opts() :: #{
    script_name => binary(),
    root_path => binary(),
    proxy_allow_from => [binary()],
    proxy_headers => [binary()]
}.

%% @doc Build a WSGI environ dictionary from a Cowboy request.
%%
%% Creates a dictionary containing all standard WSGI variables.
-spec build_environ(cowboy_req:req()) -> map().
build_environ(Req) ->
    build_environ(Req, #{}).

%% @doc Build a WSGI environ dictionary with options.
%%
%% Options:
%% - script_name: Override SCRIPT_NAME (default: empty binary)
%% - root_path: Root path for the application
%% - proxy_allow_from: IPs allowed to send proxy headers
%% - proxy_headers: Headers to check for proxied client info
-spec build_environ(cowboy_req:req(), environ_opts()) -> map().
build_environ(Req, Opts) ->
    %% Get basic request info
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),

    %% Get client info
    {ClientIp, ClientPort} = cowboy_req:peer(Req),

    %% Check for proxy headers (X-Forwarded-For, X-Real-IP, etc.)
    {RemoteAddr, RemotePort} = get_remote_addr(Headers, ClientIp, ClientPort, Opts),

    %% Read body for wsgi.input
    {ok, Body, _Req2} = cowboy_req:read_body(Req),

    %% Get SCRIPT_NAME from options or default
    ScriptName = maps:get(script_name, Opts, <<>>),

    %% Build base environ
    BaseEnviron = #{
        %% Required CGI variables
        <<"REQUEST_METHOD">> => Method,
        <<"SCRIPT_NAME">> => ScriptName,
        <<"PATH_INFO">> => Path,
        <<"QUERY_STRING">> => Qs,
        <<"SERVER_NAME">> => Host,
        <<"SERVER_PORT">> => integer_to_binary(Port),
        <<"SERVER_PROTOCOL">> => format_protocol(Version),

        %% Required WSGI variables
        <<"wsgi.version">> => [1, 0],
        <<"wsgi.url_scheme">> => Scheme,
        <<"wsgi.input">> => Body,
        <<"wsgi.errors">> => <<"stderr">>,
        <<"wsgi.multithread">> => true,
        <<"wsgi.multiprocess">> => true,
        <<"wsgi.run_once">> => false,

        %% Recommended extensions (handled in Python runner)
        %% wsgi.file_wrapper - set in Python
        %% wsgi.input_terminated - set in Python
        %% wsgi.early_hints - set in Python

        %% Client info
        <<"REMOTE_ADDR">> => RemoteAddr,
        <<"REMOTE_PORT">> => integer_to_binary(RemotePort)
    },

    %% Add CONTENT_TYPE and CONTENT_LENGTH if present
    Environ1 = case maps:get(<<"content-type">>, Headers, undefined) of
        undefined -> BaseEnviron;
        CT -> BaseEnviron#{<<"CONTENT_TYPE">> => CT}
    end,

    Environ2 = case maps:get(<<"content-length">>, Headers, undefined) of
        undefined -> Environ1;
        CL -> Environ1#{<<"CONTENT_LENGTH">> => CL}
    end,

    %% Add HTTP_* headers
    add_http_headers(Headers, Environ2).

%% @private
%% Get remote address, checking proxy headers if configured
get_remote_addr(Headers, ClientIp, ClientPort, Opts) ->
    ProxyAllowFrom = maps:get(proxy_allow_from, Opts, []),
    ProxyHeaders = maps:get(proxy_headers, Opts,
                           [<<"x-forwarded-for">>, <<"x-real-ip">>]),

    ClientIpBin = format_ip(ClientIp),

    %% Check if client is in proxy allowlist
    case is_proxy_allowed(ClientIpBin, ProxyAllowFrom) of
        true ->
            %% Try to get real client IP from proxy headers
            case get_forwarded_addr(Headers, ProxyHeaders) of
                {ok, ForwardedAddr} -> {ForwardedAddr, 0};
                not_found -> {ClientIpBin, ClientPort}
            end;
        false ->
            {ClientIpBin, ClientPort}
    end.

%% @private
is_proxy_allowed(_ClientIp, []) -> false;
is_proxy_allowed(ClientIp, AllowList) ->
    lists:member(ClientIp, AllowList).

%% @private
get_forwarded_addr(Headers, [Header | Rest]) ->
    case maps:get(Header, Headers, undefined) of
        undefined ->
            get_forwarded_addr(Headers, Rest);
        Value ->
            %% X-Forwarded-For can contain multiple IPs, take first
            case binary:split(Value, <<",">>) of
                [Ip | _] -> {ok, string:trim(Ip)};
                _ -> {ok, Value}
            end
    end;
get_forwarded_addr(_Headers, []) ->
    not_found.

%% @private
format_protocol('HTTP/1.0') -> <<"HTTP/1.0">>;
format_protocol('HTTP/1.1') -> <<"HTTP/1.1">>;
format_protocol('HTTP/2') -> <<"HTTP/2">>;
format_protocol(_) -> <<"HTTP/1.1">>.

%% @private
format_ip({A, B, C, D}) ->
    iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A, B, C, D]));
format_ip(Ip) when is_binary(Ip) ->
    Ip;
format_ip(Ip) when is_list(Ip) ->
    list_to_binary(Ip).

%% @private
add_http_headers(Headers, Environ) ->
    maps:fold(fun(Name, Value, Acc) ->
        %% Skip content-type and content-length (handled separately)
        case Name of
            <<"content-type">> -> Acc;
            <<"content-length">> -> Acc;
            _ ->
                %% Convert header name to HTTP_* format
                HttpName = header_to_cgi(Name),
                Acc#{HttpName => Value}
        end
    end, Environ, Headers).

%% @private
%% Convert header name to CGI format: foo-bar -> HTTP_FOO_BAR
header_to_cgi(Name) when is_binary(Name) ->
    Upper = string:uppercase(Name),
    Underscored = binary:replace(Upper, <<"-">>, <<"_">>, [global]),
    <<"HTTP_", Underscored/binary>>.
