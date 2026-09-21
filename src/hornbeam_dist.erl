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

%% Bounds on atoms minted from caller-supplied node names.
-define(MAX_NODE_ATOMS, 256).
-define(MAX_NODE_NAME_BYTES, 255).
-define(NODE_ATOM_COUNT, {?MODULE, node_atom_count}).

%% @doc Call a function on a remote node synchronously.
%% Returns {ok, Result} or {error, Reason}.
-spec rpc_call(Node :: atom() | binary(),
               Module :: atom() | binary(),
               Function :: atom() | binary(),
               Args :: list(),
               Timeout :: pos_integer()) ->
    {ok, term()} | {error, term()}.
rpc_call(Node, Module, Function, Args, Timeout) ->
    case resolve_mfa(Node, Module, Function) of
        {ok, NodeAtom, ModuleAtom, FunctionAtom} ->
            case rpc:call(NodeAtom, ModuleAtom, FunctionAtom, Args, Timeout) of
                {badrpc, Reason} -> {error, Reason};
                Result -> {ok, Result}
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc Call a function on a remote node asynchronously (fire and forget).
-spec rpc_cast(Node :: atom() | binary(),
               Module :: atom() | binary(),
               Function :: atom() | binary(),
               Args :: list()) -> ok | {error, term()}.
rpc_cast(Node, Module, Function, Args) ->
    case resolve_mfa(Node, Module, Function) of
        {ok, NodeAtom, ModuleAtom, FunctionAtom} ->
            rpc:cast(NodeAtom, ModuleAtom, FunctionAtom, Args),
            ok;
        {error, _} = Err ->
            Err
    end.

%% @private Resolve the three names of an RPC in one place, so both
%% rpc_call/5 and rpc_cast/4 refuse the same inputs for the same reason.
resolve_mfa(Node, Module, Function) ->
    case {to_node_atom(Node), to_existing_atom(Module),
          to_existing_atom(Function)} of
        {{ok, N}, {ok, M}, {ok, F}} -> {ok, N, M, F};
        {{error, _} = Err, _, _} -> Err;
        {_, {error, _} = Err, _} -> Err;
        {_, _, {error, _} = Err} -> Err
    end.

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
    case to_node_atom(Node) of
        {ok, Atom} -> net_adm:ping(Atom);
        {error, _} -> pang
    end.

%% @doc Connect to a node.
-spec connect(Node :: atom() | binary()) -> boolean().
connect(Node) ->
    case to_node_atom(Node) of
        {ok, Atom} -> net_kernel:connect_node(Atom);
        {error, _} -> false
    end.

%% @doc Disconnect from a node.
-spec disconnect(Node :: atom() | binary()) -> boolean() | ignored.
disconnect(Node) ->
    %% A node this VM has never named cannot be connected, so there is
    %% nothing to disconnect and no reason to mint an atom for it.
    case to_existing_atom(Node) of
        {ok, Atom} -> erlang:disconnect_node(Atom);
        {error, _} -> false
    end.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

%% Names arriving here come from Python, so they are caller-supplied.
%% The atom table is node-wide and never garbage collected, so converting
%% them with binary_to_atom/2 is an exhaustion path: a loop calling
%% rpc_call with a fresh module name eventually kills the VM.
%%
%% Module and function names must therefore already exist as atoms. They
%% always do for code this node can reach, because loading a module
%% creates them; a name that does not exist names nothing callable, so
%% refusing it loses nothing.
-spec to_existing_atom(atom() | binary() | list()) ->
    {ok, atom()} | {error, {unknown_name, binary()}}.
to_existing_atom(V) when is_atom(V) ->
    {ok, V};
to_existing_atom(V) when is_list(V) ->
    to_existing_atom(unicode:characters_to_binary(V));
to_existing_atom(V) when is_binary(V) ->
    try {ok, binary_to_existing_atom(V, utf8)}
    catch error:badarg -> {error, {unknown_name, V}}
    end.

%% Node names are the one case where a new atom is legitimate: connecting
%% to a node this VM has never seen has to name it. So they are bounded
%% instead of refused - the shape is checked and the number hornbeam will
%% ever mint is capped, which keeps the exhaustion path closed while
%% leaving the feature usable.
-spec to_node_atom(atom() | binary() | list()) ->
    {ok, node()} | {error, term()}.
to_node_atom(V) when is_atom(V) ->
    {ok, V};
to_node_atom(V) when is_list(V) ->
    to_node_atom(unicode:characters_to_binary(V));
to_node_atom(V) when is_binary(V) ->
    case to_existing_atom(V) of
        {ok, Atom} ->
            %% Already known: every connected or previously named node
            %% takes this path, so the cap is only reached by genuinely
            %% new names.
            {ok, Atom};
        {error, _} ->
            mint_node_atom(V)
    end.

mint_node_atom(Bin) when byte_size(Bin) > ?MAX_NODE_NAME_BYTES ->
    {error, {invalid_node_name, Bin}};
mint_node_atom(Bin) ->
    case binary:split(Bin, <<"@">>, [global]) of
        [Name, Host] when Name =/= <<>>, Host =/= <<>> ->
            case bump_node_atom_count() of
                ok -> {ok, binary_to_atom(Bin, utf8)};
                {error, _} = Err -> Err
            end;
        _ ->
            {error, {invalid_node_name, Bin}}
    end.

%% A counter rather than a set: the point is to bound how many atoms can
%% be created, not to remember which. Racing callers may overshoot the
%% cap by the number of concurrent minters, which is fine for a bound
%% whose job is to stop an unbounded loop.
bump_node_atom_count() ->
    N = persistent_term:get(?NODE_ATOM_COUNT, 0),
    case N >= ?MAX_NODE_ATOMS of
        true ->
            {error, node_atom_limit_reached};
        false ->
            persistent_term:put(?NODE_ATOM_COUNT, N + 1),
            ok
    end.
