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

%%% @doc Distributed Erlang RPC for Python apps.
%%%
%%% This module lets Python apps call functions on remote Erlang nodes.
%%% Use cases:
%%% - Distributed ML inference across GPU nodes
%%% - Sharding data processing across cluster
%%% - Calling specialized services on different nodes
%%%
%%% Erlang distribution provides:
%%% - Transparent RPC (call any node in cluster)
%%% - Node discovery and monitoring
%%% - Fault-tolerant (handle node failures)
-module(hornbeam_dist).

-export([
    rpc_call/5,
    rpc_cast/4,
    nodes/0,
    connected_nodes/0,
    node/0,
    ping/1,
    connect/1,
    disconnect/1
]).

%% @doc Call a function on a remote node synchronously.
%% Returns {ok, Result} or {error, Reason}.
-spec rpc_call(Node :: atom() | binary(),
               Module :: atom() | binary(),
               Function :: atom() | binary(),
               Args :: list(),
               Timeout :: pos_integer()) ->
    {ok, term()} | {error, term()}.
rpc_call(Node, Module, Function, Args, Timeout) ->
    NodeAtom = to_atom(Node),
    ModuleAtom = to_atom(Module),
    FunctionAtom = to_atom(Function),

    case rpc:call(NodeAtom, ModuleAtom, FunctionAtom, Args, Timeout) of
        {badrpc, Reason} ->
            {error, Reason};
        Result ->
            {ok, Result}
    end.

%% @doc Call a function on a remote node asynchronously (fire and forget).
-spec rpc_cast(Node :: atom() | binary(),
               Module :: atom() | binary(),
               Function :: atom() | binary(),
               Args :: list()) -> ok.
rpc_cast(Node, Module, Function, Args) ->
    NodeAtom = to_atom(Node),
    ModuleAtom = to_atom(Module),
    FunctionAtom = to_atom(Function),

    rpc:cast(NodeAtom, ModuleAtom, FunctionAtom, Args),
    ok.

%% @doc Get list of all known nodes (including disconnected).
-spec nodes() -> [atom()].
nodes() ->
    erlang:nodes(known).

%% @doc Get list of connected nodes.
-spec connected_nodes() -> [atom()].
connected_nodes() ->
    erlang:nodes(connected).

%% @doc Get this node's name.
-spec node() -> atom().
node() ->
    erlang:node().

%% @doc Ping a node to check if it's alive.
-spec ping(Node :: atom() | binary()) -> pong | pang.
ping(Node) ->
    net_adm:ping(to_atom(Node)).

%% @doc Connect to a node.
-spec connect(Node :: atom() | binary()) -> boolean().
connect(Node) ->
    net_kernel:connect_node(to_atom(Node)).

%% @doc Disconnect from a node.
-spec disconnect(Node :: atom() | binary()) -> boolean() | ignored.
disconnect(Node) ->
    erlang:disconnect_node(to_atom(Node)).

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

to_atom(V) when is_atom(V) -> V;
to_atom(V) when is_binary(V) -> binary_to_atom(V, utf8);
to_atom(V) when is_list(V) -> list_to_atom(V).
