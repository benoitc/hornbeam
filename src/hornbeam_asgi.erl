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

%%% @doc ASGI handler using Cowboy loop handler.
%%%
%%% This module implements ASGI request handling using Cowboy's async body
%%% reading via loop handlers. Request body is streamed via channels,
%%% response is sent directly via erlang.send().
%%%
%%% @end
-module(hornbeam_asgi).

-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

%% Internal state
-record(state, {
    req_info,
    app_module,
    app_callable,
    timeout_ms,
    scope,
    req_body_ch,
    body_ref,           %% Reference for async body reading
    has_body,
    headers_sent = false,
    buffered_headers,   %% {StatusCode, Headers, HasContentLength} or undefined
    handler_state       %% Original handler state from init
}).

%%% ============================================================================
%%% Cowboy Loop Handler Callbacks
%%% ============================================================================

init(Req, HandlerState) ->
    ReqInfo = build_request_info(Req),
    ReqInfo1 = hornbeam_http_hooks:run_on_request(ReqInfo),

    AppModule = maps:get(app_module, HandlerState),
    AppCallable = maps:get(app_callable, HandlerState),
    TimeoutMs = maps:get(timeout, HandlerState, 30000),

    %% Build ASGI scope
    Scope = hornbeam_request:build_asgi_scope(Req, HandlerState),

    %% Check if request has a body
    %% Body exists if: Content-Length > 0, or Transfer-Encoding is present
    Method = cowboy_req:method(Req),
    ContentLength = get_content_length(Req),
    TransferEncoding = cowboy_req:header(<<"transfer-encoding">>, Req),
    HasBody = has_request_body(Method, ContentLength, TransferEncoding),

    %% Create request body channel only if body exists (skip for GET/no-body)
    {ReqBodyCh, BodyRef} = case HasBody of
        true ->
            {ok, Ch} = py_byte_channel:new(),
            Ref = make_ref(),
            %% Start async body reading - Cowboy will send us messages
            cowboy_req:cast({read_body, self(), Ref, auto, infinity}, Req),
            {Ch, Ref};
        false ->
            %% No body - pass empty marker, skip channel
            {empty, undefined}
    end,

    %% Create Python task (response sent via erlang.send, no channel needed)
    _TaskRef = py_event_loop_pool:create_task(
        <<"hornbeam_asgi_worker">>, <<"handle_asgi">>,
        [self(), AppModule, AppCallable, Scope, ReqBodyCh]),

    State = #state{
        req_info = ReqInfo1,
        app_module = AppModule,
        app_callable = AppCallable,
        timeout_ms = TimeoutMs,
        scope = Scope,
        req_body_ch = ReqBodyCh,
        body_ref = BodyRef,
        has_body = HasBody,
        handler_state = HandlerState
    },

    %% Return cowboy_loop to enable loop handler
    {cowboy_loop, Req, State, TimeoutMs}.

%% Handle async body chunks from Cowboy
info({request_body, Ref, nofin, Data}, Req, #state{body_ref = Ref, req_body_ch = Ch} = State) ->
    %% More body data coming - push to channel
    ok = push_to_channel(Ch, Data),
    %% Request more data
    cowboy_req:cast({read_body, self(), Ref, auto, infinity}, Req),
    {ok, Req, State};

info({request_body, Ref, fin, _BodyLen, Data}, Req, #state{body_ref = Ref, req_body_ch = Ch} = State) ->
    %% Final chunk - push and close channel
    case Data of
        <<>> -> ok;
        _ -> ok = push_to_channel(Ch, Data)
    end,
    py_byte_channel:close(Ch),
    {ok, Req, State#state{body_ref = undefined}};

%% Handle response headers from Python
%% Buffer headers until we get body - then decide reply vs stream based on content-length
info({<<"headers">>, StatusCode, Headers}, Req, State) ->
    SafeHeaders = filter_hop_by_hop(Headers),
    CowboyHeaders = convert_headers(SafeHeaders),
    HasContentLength = maps:is_key(<<"content-length">>, CowboyHeaders),
    {ok, Req, State#state{
        headers_sent = false,
        buffered_headers = {StatusCode, CowboyHeaders, HasContentLength}
    }};

%% Handle response body from Python
info({<<"body">>, Body, MoreBody}, Req, #state{handler_state = HandlerState,
                                               buffered_headers = BufferedHeaders} = State) ->
    BodyBin = to_binary(Body),
    case {BufferedHeaders, MoreBody} of
        %% First body chunk with buffered headers
        {{StatusCode, CowboyHeaders, true}, false} ->
            %% Has Content-Length and no more body - use reply (not streaming)
            Req2 = cowboy_req:reply(StatusCode, CowboyHeaders, BodyBin, Req),
            maybe_close_channel(State#state.req_body_ch),
            {stop, Req2, HandlerState};
        {{StatusCode, CowboyHeaders, _HasCL}, _} ->
            %% Streaming response - start with stream_reply
            Req2 = cowboy_req:stream_reply(StatusCode, CowboyHeaders, Req),
            case MoreBody of
                true ->
                    case BodyBin of
                        <<>> -> ok;
                        _ -> ok = cowboy_req:stream_body(BodyBin, nofin, Req2)
                    end,
                    {ok, Req2, State#state{headers_sent = true, buffered_headers = undefined}};
                false ->
                    ok = cowboy_req:stream_body(BodyBin, fin, Req2),
                    maybe_close_channel(State#state.req_body_ch),
                    {stop, Req2, HandlerState}
            end;
        %% Subsequent body chunks (headers already sent)
        {undefined, true} ->
            ok = cowboy_req:stream_body(BodyBin, nofin, Req),
            {ok, Req, State};
        {undefined, false} ->
            ok = cowboy_req:stream_body(BodyBin, fin, Req),
            maybe_close_channel(State#state.req_body_ch),
            {stop, Req, HandlerState}
    end;

%% Handle early hints from Python
info({<<"early_hints">>, Headers}, Req, State) ->
    HintHeaders = convert_headers(Headers),
    Req2 = cowboy_req:inform(103, HintHeaders, Req),
    {ok, Req2, State};

%% Handle error from Python
info({<<"error">>, Reason}, Req, #state{req_info = ReqInfo, handler_state = HandlerState} = State) ->
    maybe_close_channel(State#state.req_body_ch),
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Reason, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body, Req),
    {stop, Req2, HandlerState};

%% Handle async task completion
info({async_result, _Ref, {ok, _}}, Req, State) ->
    {ok, Req, State};

info({async_result, _Ref, {error, Reason}}, Req, #state{req_info = ReqInfo, handler_state = HandlerState} = State) ->
    maybe_close_channel(State#state.req_body_ch),
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Reason, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body, Req),
    {stop, Req2, HandlerState};

%% Handle timeout
info(timeout, Req, #state{req_info = ReqInfo, handler_state = HandlerState} = State) ->
    maybe_close_channel(State#state.req_body_ch),
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(timeout, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body, Req),
    {stop, Req2, HandlerState};

%% Unknown message
info(_Msg, Req, State) ->
    {ok, Req, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

push_to_channel(Channel, Data) ->
    case py_byte_channel:send(Channel, Data) of
        ok -> ok;
        busy ->
            %% Channel full - wait a bit and retry
            timer:sleep(1),
            push_to_channel(Channel, Data);
        {error, closed} ->
            ok
    end.

maybe_close_channel(undefined) -> ok;
maybe_close_channel(empty) -> ok;
maybe_close_channel(Channel) ->
    try
        case py_byte_channel:info(Channel) of
            #{closed := true} -> ok;
            _ ->
                catch py_byte_channel:close(Channel),
                ok
        end
    catch
        _:_ -> ok
    end.

%% @private
get_content_length(Req) ->
    case cowboy_req:header(<<"content-length">>, Req) of
        undefined -> undefined;
        CLBin ->
            try binary_to_integer(CLBin)
            catch _:_ -> undefined
            end
    end.

%% @private
%% Check if request has a body based on method, content-length, and transfer-encoding
%% Per HTTP spec: body exists if Content-Length > 0 OR Transfer-Encoding is present
has_request_body(_, _, TE) when TE =/= undefined -> true;  %% Transfer-Encoding present
has_request_body(_, 0, _) -> false;                         %% Content-Length: 0
has_request_body(_, CL, _) when is_integer(CL), CL > 0 -> true;  %% Content-Length > 0
has_request_body(<<"GET">>, _, _) -> false;
has_request_body(<<"HEAD">>, _, _) -> false;
has_request_body(<<"DELETE">>, _, _) -> false;
has_request_body(<<"OPTIONS">>, _, _) -> false;
has_request_body(_, undefined, undefined) -> false.         %% No CL, no TE = no body

%% @private
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

%% @private
filter_hop_by_hop(Headers) ->
    HopByHop = [<<"connection">>, <<"keep-alive">>, <<"proxy-authenticate">>,
                <<"proxy-authorization">>, <<"te">>, <<"trailers">>,
                <<"transfer-encoding">>, <<"upgrade">>],
    lists:filter(fun(Header) ->
        Name = case Header of
            [N, _] -> N;
            {N, _} -> N
        end,
        LowerName = string:lowercase(to_binary(Name)),
        not lists:member(LowerName, HopByHop)
    end, Headers).

%% @private
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
