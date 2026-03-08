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

%%% @doc Unix socketpair creation and management for hornbeam.
%%%
%%% Creates Unix socketpairs for communication between Erlang and Python.
%%% Each socketpair provides bidirectional communication:
%%% - ErlangFd: Erlang writes request, reads response
%%% - PythonFd: Python reads request, writes response
%%%
%%% The socketpair uses AF_UNIX/SOCK_STREAM for reliable streaming.
-module(hornbeam_socketpair).

-export([
    create/0,
    close/1
]).

%% @doc Create a new socketpair.
%%
%% Returns {ok, {ErlangFd, PythonFd}} where:
%% - ErlangFd: FD for Erlang side (write requests, read responses)
%% - PythonFd: FD for Python side (read requests, write responses)
%%
%% Both FDs are set to non-blocking mode.
-spec create() -> {ok, {integer(), integer()}} | {error, term()}.
create() ->
    %% Use py_nif:socketpair/0 if available (provides NIF-based socketpair)
    case erlang:function_exported(py_nif, socketpair, 0) of
        true ->
            py_nif:socketpair();
        false ->
            %% Fallback: create via port command
            create_via_port()
    end.

%% @doc Close a socketpair FD.
-spec close(integer()) -> ok | {error, term()}.
close(Fd) when is_integer(Fd) ->
    py_nif:fd_close(Fd).

%%% ============================================================================
%%% Internal functions
%%% ============================================================================

%% @private
%% Create socketpair via external port command
create_via_port() ->
    %% This is a fallback for when py_nif:socketpair is not available
    %% We use a small helper script
    PrivDir = code:priv_dir(hornbeam),
    Script = filename:join(PrivDir, "socketpair_helper"),
    case filelib:is_file(Script) of
        true ->
            Port = open_port({spawn_executable, Script},
                            [stream, binary, exit_status, use_stdio]),
            receive
                {Port, {data, <<ErlangFd:32/native, PythonFd:32/native>>}} ->
                    port_close(Port),
                    {ok, {ErlangFd, PythonFd}};
                {Port, {exit_status, Status}} ->
                    {error, {exit_status, Status}}
            after 5000 ->
                port_close(Port),
                {error, timeout}
            end;
        false ->
            {error, socketpair_not_available}
    end.
