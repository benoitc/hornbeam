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

%%% @doc ASGI scope builder and protocol handling.
%%%
%%% Builds ASGI 3.0 compliant scope dictionaries from Cowboy requests.
-module(hornbeam_asgi).

-export([
    build_scope/1
]).

%% @doc Build an ASGI scope dictionary from a Cowboy request.
%%
%% Creates a scope dictionary for HTTP requests containing:
%% - type: "http"
%% - asgi: version info
%% - http_version, method, scheme, path, query_string
%% - headers: list of [name, value] pairs
%% - server: [host, port]
%% - client: [ip, port] (if available)
-spec build_scope(cowboy_req:req()) -> map().
build_scope(Req) ->
    %% Get basic request info
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    RawPath = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),

    %% Get client info
    {ClientIp, ClientPort} = cowboy_req:peer(Req),

    %% Convert headers to list of [name, value] pairs
    HeaderList = maps:fold(fun(Name, Value, Acc) ->
        [[Name, Value] | Acc]
    end, [], Headers),

    #{
        <<"type">> => <<"http">>,
        <<"asgi">> => #{
            <<"version">> => <<"3.0">>,
            <<"spec_version">> => <<"2.3">>
        },
        <<"http_version">> => format_http_version(Version),
        <<"method">> => Method,
        <<"scheme">> => Scheme,
        <<"path">> => Path,
        <<"raw_path">> => RawPath,
        <<"query_string">> => Qs,
        <<"root_path">> => <<>>,
        <<"headers">> => HeaderList,
        <<"server">> => [Host, Port],
        <<"client">> => [format_ip(ClientIp), ClientPort]
    }.

%% @private
format_http_version('HTTP/1.0') -> <<"1.0">>;
format_http_version('HTTP/1.1') -> <<"1.1">>;
format_http_version('HTTP/2') -> <<"2">>;
format_http_version(_) -> <<"1.1">>.

%% @private
format_ip({A, B, C, D}) ->
    iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A, B, C, D]));
format_ip(Ip) when is_binary(Ip) ->
    Ip;
format_ip(Ip) when is_list(Ip) ->
    list_to_binary(Ip).
