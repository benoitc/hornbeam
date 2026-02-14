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
-module(hornbeam_wsgi).

-export([
    build_environ/1
]).

%% @doc Build a WSGI environ dictionary from a Cowboy request.
%%
%% Creates a dictionary containing all standard WSGI variables:
%% - REQUEST_METHOD, SCRIPT_NAME, PATH_INFO, QUERY_STRING
%% - CONTENT_TYPE, CONTENT_LENGTH
%% - SERVER_NAME, SERVER_PORT, SERVER_PROTOCOL
%% - HTTP_* headers
%% - wsgi.* variables
-spec build_environ(cowboy_req:req()) -> map().
build_environ(Req) ->
    %% Get basic request info
    Method = cowboy_req:method(Req),
    Path = cowboy_req:path(Req),
    Qs = cowboy_req:qs(Req),
    Headers = cowboy_req:headers(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    Scheme = cowboy_req:scheme(Req),
    Version = cowboy_req:version(Req),

    %% Read body for wsgi.input
    {ok, Body, _Req2} = cowboy_req:read_body(Req),

    %% Build base environ
    BaseEnviron = #{
        <<"REQUEST_METHOD">> => Method,
        <<"SCRIPT_NAME">> => <<>>,
        <<"PATH_INFO">> => Path,
        <<"QUERY_STRING">> => Qs,
        <<"SERVER_NAME">> => Host,
        <<"SERVER_PORT">> => integer_to_binary(Port),
        <<"SERVER_PROTOCOL">> => format_protocol(Version),
        <<"wsgi.version">> => [1, 0],
        <<"wsgi.url_scheme">> => Scheme,
        <<"wsgi.input">> => Body,
        <<"wsgi.errors">> => <<"stderr">>,
        <<"wsgi.multithread">> => true,
        <<"wsgi.multiprocess">> => true,
        <<"wsgi.run_once">> => false
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
format_protocol('HTTP/1.0') -> <<"HTTP/1.0">>;
format_protocol('HTTP/1.1') -> <<"HTTP/1.1">>;
format_protocol('HTTP/2') -> <<"HTTP/2">>;
format_protocol(_) -> <<"HTTP/1.1">>.

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
