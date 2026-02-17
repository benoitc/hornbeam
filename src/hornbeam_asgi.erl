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
%%% Supports HTTP/1.1, HTTP/2, and WebSocket scopes with proper extensions.
%%%
%%% == HTTP Scope ==
%%% Contains: type, asgi, http_version, method, scheme, path, query_string,
%%% headers, server, client, root_path, state, extensions
%%%
%%% == Extensions ==
%%% - http.response.trailers: Trailer support for HTTP/2
%%% - http.response.push: Server push for HTTP/2
-module(hornbeam_asgi).

-export([
    build_scope/1,
    build_scope/2
]).

-type scope_opts() :: #{
    root_path => binary(),
    state => map(),
    extensions => map()
}.

%% @doc Build an ASGI scope dictionary from a Cowboy request.
-spec build_scope(cowboy_req:req()) -> map().
build_scope(Req) ->
    build_scope(Req, #{}).

%% @doc Build an ASGI scope dictionary with options.
%%
%% Options:
%% - root_path: ASGI root_path (default: empty binary)
%% - state: Shared state dict from lifespan (default: empty map)
%% - extensions: Additional extensions to include
-spec build_scope(cowboy_req:req(), scope_opts()) -> map().
build_scope(Req, Opts) ->
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

    %% Get root_path and state from options or lifespan
    RootPath = maps:get(root_path, Opts, get_root_path()),
    State = maps:get(state, Opts, get_lifespan_state()),

    %% Build extensions based on HTTP version
    Extensions = build_extensions(Version, Opts),

    #{
        <<"type">> => <<"http">>,
        <<"asgi">> => #{
            <<"version">> => <<"3.0">>,
            <<"spec_version">> => <<"2.4">>
        },
        <<"http_version">> => format_http_version(Version),
        <<"method">> => Method,
        <<"scheme">> => Scheme,
        <<"path">> => Path,
        <<"raw_path">> => RawPath,
        <<"query_string">> => Qs,
        <<"root_path">> => RootPath,
        <<"headers">> => HeaderList,
        <<"server">> => [Host, Port],
        <<"client">> => [format_ip(ClientIp), ClientPort],
        <<"state">> => State,
        <<"extensions">> => Extensions
    }.

%% @private
get_root_path() ->
    case hornbeam_config:get_config(root_path) of
        undefined -> <<>>;
        Path -> ensure_binary(Path)
    end.

%% @private
get_lifespan_state() ->
    case catch hornbeam_lifespan:get_state() of
        State when is_map(State) -> State;
        _ -> #{}
    end.

%% @private
%% Build ASGI extensions based on HTTP version
build_extensions(Version, Opts) ->
    BaseExtensions = maps:get(extensions, Opts, #{}),

    %% Add HTTP/2 specific extensions
    case Version of
        'HTTP/2' ->
            BaseExtensions#{
                <<"http.response.trailers">> => #{},
                <<"http.response.early_hints">> => #{}
            };
        _ ->
            %% HTTP/1.1 still supports early hints
            BaseExtensions#{
                <<"http.response.early_hints">> => #{}
            }
    end.

%% @private
format_http_version('HTTP/1.0') -> <<"1.0">>;
format_http_version('HTTP/1.1') -> <<"1.1">>;
format_http_version('HTTP/2') -> <<"2">>.

%% @private
%% IPv4 - optimized to avoid io_lib:format overhead
format_ip({A, B, C, D}) ->
    list_to_binary([
        integer_to_list(A), $.,
        integer_to_list(B), $.,
        integer_to_list(C), $.,
        integer_to_list(D)
    ]);
%% IPv6 - use inet:ntoa which is implemented in C
format_ip(Addr = {_, _, _, _, _, _, _, _}) ->
    list_to_binary(inet:ntoa(Addr)).

%% @private
ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).
