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

%%% @doc ASGI handler using Cowboy loop handler with push/pull body streaming.
%%%
%%% This module implements ASGI request handling using Cowboy's async body
%%% reading via loop handlers. Instead of spawning a pump process, it uses
%%% cowboy_req:cast to receive body chunks as messages, which are then
%%% pushed to Python via channel.
%%%
%%% Architecture:
%%% - Cowboy sends {request_body, Ref, nofin|fin, Data} messages
%%% - Loop handler info/3 pushes chunks to Python channel
%%% - Python buffers chunks and signals via asyncio.Event
%%% - ASGI receive() pulls from buffer
%%%
%%% Benefits over pump process approach:
%%% - No extra process spawn per request
%%% - Event-driven data flow
%%% - Natural backpressure via channel
%%% - Better integration with Cowboy's internals
%%%
%%% @end
-module(hornbeam_asgi_loop).

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
    resp_body_ch,
    body_ref,           %% Reference for async body reading
    has_body,
    headers_sent = false,
    handler_state       %% Original handler state from init
}).

-define(CHUNK_COALESCE_SIZE, 4096).
-define(CHUNK_COALESCE_TIMEOUT, 1).

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

    %% Create channels
    {ok, ReqBodyCh} = py_byte_channel:new(),
    {ok, RespBodyCh} = py_byte_channel:new(),

    %% Check if request has a body
    Method = cowboy_req:method(Req),
    ContentLength = get_content_length(Req),
    HasBody = has_request_body(Method, ContentLength),

    %% Start async body reading if there's a body
    BodyRef = case HasBody of
        true ->
            Ref = make_ref(),
            %% Start async body reading - Cowboy will send us messages
            cowboy_req:cast({read_body, self(), Ref, auto, infinity}, Req),
            Ref;
        false ->
            %% No body - close channel immediately
            py_byte_channel:close(ReqBodyCh),
            undefined
    end,

    %% Create Python task
    _TaskRef = py_event_loop_pool:create_task(
        <<"hornbeam_asgi_loop">>, <<"handle_asgi_loop">>,
        [self(), AppModule, AppCallable, Scope, ReqBodyCh, RespBodyCh]),

    State = #state{
        req_info = ReqInfo1,
        app_module = AppModule,
        app_callable = AppCallable,
        timeout_ms = TimeoutMs,
        scope = Scope,
        req_body_ch = ReqBodyCh,
        resp_body_ch = RespBodyCh,
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
info({<<"headers">>, StatusCode, Headers}, Req, State) ->
    SafeHeaders = filter_hop_by_hop(Headers),
    CowboyHeaders = convert_headers(SafeHeaders),
    Req2 = cowboy_req:stream_reply(StatusCode, CowboyHeaders, Req),
    %% Start draining response channel
    self() ! drain_response,
    {ok, Req2, State#state{headers_sent = true}};

%% Handle early hints from Python
info({<<"early_hints">>, Headers}, Req, State) ->
    HintHeaders = convert_headers(Headers),
    Req2 = cowboy_req:inform(103, HintHeaders, Req),
    {ok, Req2, State};

%% Drain response body channel
info(drain_response, Req, #state{resp_body_ch = RespBodyCh, handler_state = HandlerState} = State) ->
    case drain_response_chunk(RespBodyCh) of
        {ok, Data} ->
            ok = cowboy_req:stream_body(Data, nofin, Req),
            self() ! drain_response,
            {ok, Req, State};
        {error, closed} ->
            ok = cowboy_req:stream_body(<<>>, fin, Req),
            {stop, Req, HandlerState};
        {error, timeout} ->
            %% No data yet, schedule retry
            erlang:send_after(?CHUNK_COALESCE_TIMEOUT, self(), drain_response),
            {ok, Req, State}
    end;

%% Handle error from Python
info({<<"error">>, Reason}, Req, #state{req_info = ReqInfo, handler_state = HandlerState} = State) ->
    maybe_close_channel(State#state.req_body_ch),
    maybe_close_channel(State#state.resp_body_ch),
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Reason, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body, Req),
    {stop, Req2, HandlerState};

%% Handle async task completion
info({async_result, _Ref, {ok, _}}, Req, State) ->
    %% Task completed, continue draining response
    {ok, Req, State};

info({async_result, _Ref, {error, Reason}}, Req, #state{req_info = ReqInfo, handler_state = HandlerState} = State) ->
    maybe_close_channel(State#state.req_body_ch),
    maybe_close_channel(State#state.resp_body_ch),
    {StatusCode, Body} = hornbeam_http_hooks:run_on_error(Reason, ReqInfo),
    Req2 = cowboy_req:reply(StatusCode,
                            #{<<"content-type">> => <<"text/plain">>},
                            Body, Req),
    {stop, Req2, HandlerState};

%% Handle timeout
info(timeout, Req, #state{req_info = ReqInfo, handler_state = HandlerState} = State) ->
    maybe_close_channel(State#state.req_body_ch),
    maybe_close_channel(State#state.resp_body_ch),
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

drain_response_chunk(RespBodyCh) ->
    py_byte_channel:recv(RespBodyCh, ?CHUNK_COALESCE_TIMEOUT).

maybe_close_channel(undefined) -> ok;
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
has_request_body(<<"GET">>, undefined) -> false;
has_request_body(<<"HEAD">>, undefined) -> false;
has_request_body(<<"DELETE">>, undefined) -> false;
has_request_body(<<"OPTIONS">>, undefined) -> false;
has_request_body(_, 0) -> false;
has_request_body(_, _) -> true.

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
