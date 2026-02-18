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

%%% @doc HTTP lifecycle hooks for request/response processing.
%%%
%%% This module provides hooks that are called at key points during
%%% HTTP request processing:
%%%
%%% - `on_request' - Called before the request is processed
%%% - `on_response' - Called before the response is sent
%%% - `on_error' - Called when an error occurs
%%%
%%% == Usage ==
%%%
%%% ```
%%% hornbeam:start("app:application", #{
%%%     hooks => #{
%%%         on_request => fun(Request) ->
%%%             logger:info("Request: ~p", [Request]),
%%%             Request
%%%         end,
%%%         on_response => fun(Response) ->
%%%             Response#{headers => maps:put(<<"x-powered-by">>, <<"Hornbeam">>,
%%%                                           maps:get(headers, Response, #{}))}
%%%         end,
%%%         on_error => fun(Error, Request) ->
%%%             {500, <<"Internal Server Error">>}
%%%         end
%%%     }
%%% }).
%%% '''
-module(hornbeam_http_hooks).

-export([
    set_hooks/1,
    get_hooks/0,
    run_on_request/1,
    run_on_response/1,
    run_on_error/2
]).

-define(HOOKS_KEY, {?MODULE, hooks}).

%% @doc Set the HTTP hooks configuration.
%% Hooks are stored in persistent_term for fast access.
-spec set_hooks(map()) -> ok.
set_hooks(Hooks) when is_map(Hooks) ->
    persistent_term:put(?HOOKS_KEY, Hooks),
    ok.

%% @doc Get the current hooks configuration.
-spec get_hooks() -> map().
get_hooks() ->
    try
        persistent_term:get(?HOOKS_KEY)
    catch
        error:badarg -> #{}
    end.

%% @doc Run the on_request hook.
%% The hook receives a request map and should return a (possibly modified) request map.
%% If no hook is configured, returns the request unchanged.
-spec run_on_request(map()) -> map().
run_on_request(Request) when is_map(Request) ->
    case maps:get(on_request, get_hooks(), undefined) of
        undefined ->
            Request;
        Hook when is_function(Hook, 1) ->
            try
                Hook(Request)
            catch
                Class:Reason:Stack ->
                    error_logger:error_msg("on_request hook error: ~p:~p~n~p~n",
                                           [Class, Reason, Stack]),
                    Request
            end
    end.

%% @doc Run the on_response hook.
%% The hook receives a response map and should return a (possibly modified) response map.
%% If no hook is configured, returns the response unchanged.
-spec run_on_response(map()) -> map().
run_on_response(Response) when is_map(Response) ->
    case maps:get(on_response, get_hooks(), undefined) of
        undefined ->
            Response;
        Hook when is_function(Hook, 1) ->
            try
                Hook(Response)
            catch
                Class:Reason:Stack ->
                    error_logger:error_msg("on_response hook error: ~p:~p~n~p~n",
                                           [Class, Reason, Stack]),
                    Response
            end
    end.

%% @doc Run the on_error hook.
%% The hook receives an error term and request map, and should return
%% {StatusCode, Body} for the error response.
%% If no hook is configured, returns a default 500 error.
-spec run_on_error(term(), map()) -> {integer(), binary()}.
run_on_error(Error, Request) ->
    case maps:get(on_error, get_hooks(), undefined) of
        undefined ->
            %% Default error response
            {500, <<"Internal Server Error">>};
        Hook when is_function(Hook, 2) ->
            try
                case Hook(Error, Request) of
                    {Code, Body} when is_integer(Code), is_binary(Body) ->
                        {Code, Body};
                    {Code, Body} when is_integer(Code), is_list(Body) ->
                        {Code, list_to_binary(Body)};
                    Other ->
                        error_logger:warning_msg("on_error hook returned invalid response: ~p~n",
                                                 [Other]),
                        {500, <<"Internal Server Error">>}
                end
            catch
                Class:Reason:Stack ->
                    error_logger:error_msg("on_error hook error: ~p:~p~n~p~n",
                                           [Class, Reason, Stack]),
                    {500, <<"Internal Server Error">>}
            end
    end.
