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
-module(hornbeam_handler).

-export([init/2]).

init(Req, State) ->
    WorkerClass = maps:get(worker_class, State, wsgi),
    handle_request(WorkerClass, Req, State).

handle_request(wsgi, Req, State) ->
    handle_wsgi(Req, State);
handle_request(asgi, Req, State) ->
    handle_asgi(Req, State).

%%% ============================================================================
%%% WSGI Handler
%%% ============================================================================

handle_wsgi(Req, State) ->
    try
        %% Build WSGI environ dict
        Environ = hornbeam_wsgi:build_environ(Req),

        %% Get app module and callable from config
        AppModule = hornbeam_config:get_config(app_module),
        AppCallable = hornbeam_config:get_config(app_callable),

        %% Call the WSGI application via Python runner
        Timeout = hornbeam_config:get_config(timeout),
        TimeoutMs = case Timeout of
            undefined -> 30000;
            T -> T
        end,

        Result = py:call(hornbeam_wsgi_runner, run_wsgi,
                        [AppModule, AppCallable, Environ], #{}, TimeoutMs),

        case Result of
            {ok, Response} ->
                Status = maps:get(<<"status">>, Response),
                Headers = maps:get(<<"headers">>, Response),
                Body = maps:get(<<"body">>, Response),
                send_wsgi_response(Req, Status, Headers, Body, State);
            {error, Error} ->
                error_response(Req, Error, State)
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("WSGI handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            error_response(Req, {Class, Reason}, State)
    end.

send_wsgi_response(Req, Status, Headers, Body, State) ->
    %% Parse status code
    StatusCode = parse_status_code(Status),

    %% Convert headers to cowboy format
    CowboyHeaders = lists:foldl(fun(Header, Acc) ->
        case Header of
            [Name, Value] ->
                Acc#{to_lower_binary(Name) => to_binary(Value)};
            {Name, Value} ->
                Acc#{to_lower_binary(Name) => to_binary(Value)};
            _ ->
                Acc
        end
    end, #{}, Headers),

    %% Send response
    Req2 = cowboy_req:reply(StatusCode, CowboyHeaders, Body, Req),
    {ok, Req2, State}.

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
    try
        %% Build ASGI scope
        Scope = hornbeam_asgi:build_scope(Req),

        %% Get app module and callable from config
        AppModule = hornbeam_config:get_config(app_module),
        AppCallable = hornbeam_config:get_config(app_callable),

        %% Read request body
        {ok, ReqBody, Req2} = cowboy_req:read_body(Req),

        %% Call the ASGI application via Python runner
        Timeout = hornbeam_config:get_config(timeout),
        TimeoutMs = case Timeout of
            undefined -> 30000;
            T -> T
        end,

        Result = py:call(hornbeam_asgi_runner, run_asgi,
                        [AppModule, AppCallable, Scope, ReqBody], #{}, TimeoutMs),

        case Result of
            {ok, Response} ->
                Status = maps:get(<<"status">>, Response),
                Headers = maps:get(<<"headers">>, Response),
                Body = maps:get(<<"body">>, Response),
                send_asgi_response(Req2, Status, Headers, Body, State);
            {error, Error} ->
                error_response(Req2, Error, State)
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg("ASGI handler error: ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            error_response(Req, {Class, Reason}, State)
    end.

send_asgi_response(Req, Status, Headers, Body, State) ->
    %% Convert status
    StatusCode = case Status of
        undefined -> 500;
        S when is_integer(S) -> S;
        S -> parse_status_code(S)
    end,

    %% Convert headers to cowboy format
    CowboyHeaders = lists:foldl(fun(Header, Acc) ->
        case Header of
            [Name, Value] ->
                Acc#{to_lower_binary(Name) => to_binary(Value)};
            {Name, Value} ->
                Acc#{to_lower_binary(Name) => to_binary(Value)};
            _ ->
                Acc
        end
    end, #{}, Headers),

    Req2 = cowboy_req:reply(StatusCode, CowboyHeaders, Body, Req),
    {ok, Req2, State}.

%%% ============================================================================
%%% Error handling
%%% ============================================================================

error_response(Req, Error, State) ->
    ErrorMsg = io_lib:format("Internal Server Error: ~p", [Error]),
    Req2 = cowboy_req:reply(500,
                            #{<<"content-type">> => <<"text/plain">>},
                            iolist_to_binary(ErrorMsg),
                            Req),
    {ok, Req2, State}.

%%% ============================================================================
%%% Utilities
%%% ============================================================================

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_lower_binary(V) when is_binary(V) -> string:lowercase(V);
to_lower_binary(V) when is_list(V) -> string:lowercase(list_to_binary(V));
to_lower_binary(V) when is_atom(V) -> string:lowercase(atom_to_binary(V, utf8));
to_lower_binary(V) -> string:lowercase(to_binary(V)).
