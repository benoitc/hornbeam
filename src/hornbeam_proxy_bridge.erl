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

%%% @doc HTTP proxy bridge for hornbeam FD reactor model.
%%%
%%% This module handles the relay of HTTP requests from Cowboy to Python
%%% reactor contexts via socketpair. It provides:
%%% - Socketpair-based bidirectional communication
%%% - PROXY v2 header encoding for client metadata
%%% - HTTP/1.1 request building from Cowboy request
%%% - Non-blocking I/O on Erlang side via enif_select
%%% - Response parsing and forwarding to client
%%%
%%% == Request Flow ==
%%%
%%% 1. Cowboy receives request, calls handle/2
%%% 2. Bridge creates socketpair
%%% 3. Bridge sends PythonFd to reactor context
%%% 4. Bridge writes PROXY v2 + HTTP/1.1 request to ErlangFd
%%% 5. Python reads, processes, writes response
%%% 6. Bridge reads response from ErlangFd
%%% 7. Bridge sends response via Cowboy
-module(hornbeam_proxy_bridge).

-export([
    handle/2,
    handle/3
]).

-record(relay_state, {
    erlang_fd :: integer(),
    python_fd :: integer(),
    req :: cowboy_req:req(),
    write_buffer :: iodata(),
    read_buffer :: binary(),
    state :: writing_request | streaming_body | reading_response,
    body_remaining :: non_neg_integer() | chunked | done,
    response_status :: binary() | undefined,
    response_headers :: [{binary(), binary()}],
    response_body :: iodata(),
    timeout :: pos_integer(),
    timer_ref :: reference() | undefined
}).

-define(DEFAULT_TIMEOUT, 30000).
-define(READ_CHUNK_SIZE, 65536).

%%% ============================================================================
%%% API
%%% ============================================================================

%% @doc Handle HTTP request via FD reactor proxy.
%%
%% This is the main entry point called from hornbeam_handler when
%% backend_mode is fd_reactor.
-spec handle(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
handle(Req, State) ->
    handle(Req, State, #{}).

%% @doc Handle HTTP request with options.
%%
%% Options:
%% - timeout: Request timeout in ms (default: 30000)
-spec handle(cowboy_req:req(), map(), map()) -> {ok, cowboy_req:req(), map()}.
handle(Req, State, Opts) ->
    Timeout = maps:get(timeout, Opts, maps:get(timeout, State, ?DEFAULT_TIMEOUT)),

    %% Create socketpair
    case hornbeam_socketpair:create() of
        {ok, {ErlangFd, PythonFd}} ->
            try
                %% Get reactor context and hand off Python FD
                {ok, ContextPid} = hornbeam_reactor_pool:get_context(),
                ClientInfo = build_client_info(Req, State),
                ContextPid ! {fd_handoff, PythonFd, ClientInfo},

                %% Build request data
                ProxyHeader = build_proxy_header(Req),
                HttpRequest = build_http_request(Req, State),

                %% Read body if present
                {BodyData, Req2} = read_request_body(Req),

                %% Start relay
                RelayState = #relay_state{
                    erlang_fd = ErlangFd,
                    python_fd = PythonFd,
                    req = Req2,
                    write_buffer = [ProxyHeader, HttpRequest, BodyData],
                    read_buffer = <<>>,
                    state = writing_request,
                    body_remaining = done,
                    response_status = undefined,
                    response_headers = [],
                    response_body = [],
                    timeout = Timeout
                },

                %% Run relay loop
                case relay_loop(RelayState) of
                    {ok, Status, Headers, Body} ->
                        Req3 = send_response(Status, Headers, Body, Req2),
                        {ok, Req3, State};
                    {error, Reason} ->
                        Req3 = send_error(500, Reason, Req2),
                        {ok, Req3, State}
                end
            after
                %% Clean up Erlang FD
                catch hornbeam_socketpair:close(ErlangFd)
            end;
        {error, Reason} ->
            error_logger:error_msg("Failed to create socketpair: ~p~n", [Reason]),
            Req2 = send_error(500, <<"Socketpair creation failed">>, Req),
            {ok, Req2, State}
    end.

%%% ============================================================================
%%% Relay Loop
%%% ============================================================================

%% @private
relay_loop(#relay_state{state = writing_request} = State) ->
    #relay_state{erlang_fd = Fd, write_buffer = Buffer, timeout = Timeout} = State,

    %% Write request to socketpair
    Data = iolist_to_binary(Buffer),
    case write_all(Fd, Data, Timeout) of
        ok ->
            %% Switch to reading response
            NewState = State#relay_state{
                state = reading_response,
                write_buffer = []
            },
            relay_loop(NewState);
        {error, Reason} ->
            {error, Reason}
    end;

relay_loop(#relay_state{state = reading_response} = State) ->
    #relay_state{erlang_fd = Fd, read_buffer = Buffer, timeout = Timeout} = State,

    %% Read response from socketpair
    case read_response(Fd, Buffer, Timeout) of
        {ok, Status, Headers, Body} ->
            {ok, Status, Headers, Body};
        {need_more, NewBuffer} ->
            %% Continue reading
            relay_loop(State#relay_state{read_buffer = NewBuffer});
        {error, Reason} ->
            {error, Reason}
    end.

%%% ============================================================================
%%% Request Building
%%% ============================================================================

%% @private
build_client_info(Req, State) ->
    {ClientIp, ClientPort} = cowboy_req:peer(Req),
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),

    #{
        peer_addr => #{ip => format_ip(ClientIp), port => ClientPort},
        server_addr => {binary_to_list(Host), Port},
        script_name => maps:get(script_name, State, <<>>),
        root_path => maps:get(script_name, State, <<>>),
        worker_class => maps:get(worker_class, State, wsgi),
        config => #{
            is_ssl => cowboy_req:scheme(Req) =:= <<"https">>,
            proxy_protocol => <<"off">>  %% We're sending PROXY v2 header
        }
    }.

%% @private
build_proxy_header(Req) ->
    {ClientIp, ClientPort} = cowboy_req:peer(Req),
    ServerIp = {0, 0, 0, 0},  %% Not critical for our use
    ServerPort = cowboy_req:port(Req),

    hornbeam_proxy_protocol:encode_v2(#{
        peer => {ClientIp, ClientPort},
        server => {ServerIp, ServerPort}
    }).

%% @private
build_http_request(Req, State) ->
    Method = cowboy_req:method(Req),
    Path = maps:get(path_info, State, cowboy_req:path(Req)),
    Qs = cowboy_req:qs(Req),
    Version = format_http_version(cowboy_req:version(Req)),
    Headers = cowboy_req:headers(Req),

    %% Build request line
    Uri = case Qs of
        <<>> -> Path;
        _ -> <<Path/binary, "?", Qs/binary>>
    end,
    RequestLine = [Method, <<" ">>, Uri, <<" ">>, Version, <<"\r\n">>],

    %% Build headers
    HeaderLines = maps:fold(fun(Name, Value, Acc) ->
        [Name, <<": ">>, Value, <<"\r\n">> | Acc]
    end, [], Headers),

    %% Add Host header if not present
    Host = cowboy_req:host(Req),
    Port = cowboy_req:port(Req),
    HostHeader = case maps:is_key(<<"host">>, Headers) of
        true -> [];
        false ->
            HostValue = case Port of
                80 -> Host;
                443 -> Host;
                _ -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>
            end,
            [<<"host: ">>, HostValue, <<"\r\n">>]
    end,

    [RequestLine, HostHeader, HeaderLines, <<"\r\n">>].

%% @private
read_request_body(Req) ->
    case cowboy_req:has_body(Req) of
        true ->
            {ok, Body, Req2} = cowboy_req:read_body(Req),
            {Body, Req2};
        false ->
            {<<>>, Req}
    end.

%%% ============================================================================
%%% I/O Operations
%%% ============================================================================

%% @private
write_all(_Fd, <<>>, _Timeout) ->
    ok;
write_all(Fd, Data, Timeout) ->
    case py_nif:fd_write(Fd, Data) of
        {ok, Written} when Written =:= byte_size(Data) ->
            ok;
        {ok, Written} ->
            %% Partial write, continue
            Rest = binary:part(Data, Written, byte_size(Data) - Written),
            %% Wait for writable
            case wait_writable(Fd, Timeout) of
                ok -> write_all(Fd, Rest, Timeout);
                Error -> Error
            end;
        {error, eagain} ->
            case wait_writable(Fd, Timeout) of
                ok -> write_all(Fd, Data, Timeout);
                Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
wait_writable(Fd, Timeout) ->
    %% Use enif_select for waiting
    case py_nif:fd_select_write(Fd) of
        ok ->
            receive
                {select, _, _, ready_output} -> ok
            after Timeout ->
                {error, timeout}
            end;
        Error ->
            Error
    end.

%% @private
read_response(Fd, Buffer, Timeout) ->
    %% Read until we have complete response
    case parse_response(Buffer) of
        {complete, Status, Headers, Body} ->
            {ok, Status, Headers, Body};
        incomplete ->
            case read_chunk(Fd, Timeout) of
                {ok, Data} ->
                    NewBuffer = <<Buffer/binary, Data/binary>>,
                    read_response(Fd, NewBuffer, Timeout);
                eof ->
                    %% Connection closed, try to parse what we have
                    case parse_response(Buffer) of
                        {complete, Status, Headers, Body} ->
                            {ok, Status, Headers, Body};
                        incomplete ->
                            {error, incomplete_response}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

%% @private
read_chunk(Fd, Timeout) ->
    case py_nif:fd_read(Fd, ?READ_CHUNK_SIZE) of
        {ok, Data} when byte_size(Data) > 0 ->
            {ok, Data};
        {ok, <<>>} ->
            eof;
        {error, eagain} ->
            %% Wait for readable
            case wait_readable(Fd, Timeout) of
                ok -> read_chunk(Fd, Timeout);
                Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
wait_readable(Fd, Timeout) ->
    case py_nif:fd_select_read(Fd) of
        ok ->
            receive
                {select, _, _, ready_input} -> ok
            after Timeout ->
                {error, timeout}
            end;
        Error ->
            Error
    end.

%%% ============================================================================
%%% Response Parsing
%%% ============================================================================

%% @private
parse_response(Data) ->
    %% Look for end of headers
    case binary:match(Data, <<"\r\n\r\n">>) of
        nomatch ->
            incomplete;
        {Pos, 4} ->
            HeaderData = binary:part(Data, 0, Pos),
            BodyStart = Pos + 4,
            Body = binary:part(Data, BodyStart, byte_size(Data) - BodyStart),

            %% Parse status line and headers
            case parse_status_and_headers(HeaderData) of
                {ok, Status, Headers} ->
                    %% Check Content-Length
                    ContentLength = get_content_length(Headers),
                    case ContentLength of
                        undefined ->
                            %% No Content-Length, assume body is complete
                            {complete, Status, Headers, Body};
                        Len when byte_size(Body) >= Len ->
                            %% Have complete body
                            {complete, Status, Headers, binary:part(Body, 0, Len)};
                        _ ->
                            %% Need more body
                            incomplete
                    end;
                error ->
                    incomplete
            end
    end.

%% @private
parse_status_and_headers(Data) ->
    Lines = binary:split(Data, <<"\r\n">>, [global]),
    case Lines of
        [StatusLine | HeaderLines] ->
            case parse_status_line(StatusLine) of
                {ok, Status} ->
                    Headers = parse_headers(HeaderLines),
                    {ok, Status, Headers};
                error ->
                    error
            end;
        _ ->
            error
    end.

%% @private
parse_status_line(Line) ->
    case binary:match(Line, <<" ">>) of
        {Pos, 1} ->
            %% Skip HTTP version
            Rest = binary:part(Line, Pos + 1, byte_size(Line) - Pos - 1),
            %% Extract status code
            case binary:match(Rest, <<" ">>) of
                {Pos2, 1} ->
                    StatusCode = binary:part(Rest, 0, Pos2),
                    {ok, binary_to_integer(StatusCode)};
                nomatch ->
                    %% Just status code, no phrase
                    {ok, binary_to_integer(Rest)}
            end;
        nomatch ->
            error
    end.

%% @private
parse_headers(Lines) ->
    parse_headers(Lines, []).

parse_headers([], Acc) ->
    lists:reverse(Acc);
parse_headers([<<>> | Rest], Acc) ->
    parse_headers(Rest, Acc);
parse_headers([Line | Rest], Acc) ->
    case binary:match(Line, <<": ">>) of
        {Pos, 2} ->
            Name = string:lowercase(binary:part(Line, 0, Pos)),
            Value = binary:part(Line, Pos + 2, byte_size(Line) - Pos - 2),
            parse_headers(Rest, [{Name, Value} | Acc]);
        nomatch ->
            %% Try with just ":"
            case binary:match(Line, <<":">>) of
                {Pos2, 1} ->
                    Name = string:lowercase(binary:part(Line, 0, Pos2)),
                    Value = string:trim(binary:part(Line, Pos2 + 1, byte_size(Line) - Pos2 - 1)),
                    parse_headers(Rest, [{Name, Value} | Acc]);
                nomatch ->
                    parse_headers(Rest, Acc)
            end
    end.

%% @private
get_content_length(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Value} ->
            try binary_to_integer(Value) catch _:_ -> undefined end;
        false ->
            undefined
    end.

%%% ============================================================================
%%% Response Sending
%%% ============================================================================

%% @private
send_response(Status, Headers, Body, Req) ->
    %% Convert headers to cowboy format
    CowboyHeaders = lists:foldl(fun({Name, Value}, Acc) ->
        Acc#{Name => Value}
    end, #{}, Headers),

    cowboy_req:reply(Status, CowboyHeaders, Body, Req).

%% @private
send_error(Status, Reason, Req) ->
    Body = io_lib:format("Error: ~p", [Reason]),
    cowboy_req:reply(Status,
                     #{<<"content-type">> => <<"text/plain">>},
                     iolist_to_binary(Body),
                     Req).

%%% ============================================================================
%%% Utilities
%%% ============================================================================

%% @private
format_ip({A, B, C, D}) ->
    list_to_binary([
        integer_to_list(A), $.,
        integer_to_list(B), $.,
        integer_to_list(C), $.,
        integer_to_list(D)
    ]);
format_ip(Addr = {_, _, _, _, _, _, _, _}) ->
    list_to_binary(inet:ntoa(Addr)).

%% @private
format_http_version('HTTP/1.0') -> <<"HTTP/1.0">>;
format_http_version('HTTP/1.1') -> <<"HTTP/1.1">>;
format_http_version('HTTP/2') -> <<"HTTP/1.1">>.  %% Translate to HTTP/1.1
