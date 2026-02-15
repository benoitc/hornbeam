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

%%% @doc Tests for hornbeam distributed Erlang RPC.
-module(hornbeam_dist_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    test_node_name/1,
    test_nodes_list/1,
    test_connected_nodes/1,
    test_ping_nonexistent/1,
    test_rpc_call_local/1,
    test_rpc_call_error/1,
    test_rpc_cast_local/1,
    test_atom_conversion/1,
    test_binary_conversion/1,
    test_list_conversion/1
]).

all() ->
    [{group, dist}].

groups() ->
    [{dist, [sequence], [
        test_node_name,
        test_nodes_list,
        test_connected_nodes,
        test_ping_nonexistent,
        test_rpc_call_local,
        test_rpc_call_error,
        test_rpc_cast_local,
        test_atom_conversion,
        test_binary_conversion,
        test_list_conversion
    ]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hornbeam),
    Config.

end_per_suite(_Config) ->
    application:stop(hornbeam),
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%% ============================================================================
%%% Test cases
%%% ============================================================================

test_node_name(_Config) ->
    %% Get node name
    Node = hornbeam_dist:node(),
    ?assert(is_atom(Node)),
    %% In test mode, typically nonode@nohost
    ?assertEqual(erlang:node(), Node).

test_nodes_list(_Config) ->
    %% Get known nodes (may be empty in single-node test)
    Nodes = hornbeam_dist:nodes(),
    ?assert(is_list(Nodes)),
    %% All items should be atoms
    lists:foreach(fun(N) -> ?assert(is_atom(N)) end, Nodes).

test_connected_nodes(_Config) ->
    %% Get connected nodes (empty in single-node test)
    Nodes = hornbeam_dist:connected_nodes(),
    ?assert(is_list(Nodes)),
    %% All items should be atoms
    lists:foreach(fun(N) -> ?assert(is_atom(N)) end, Nodes).

test_ping_nonexistent(_Config) ->
    %% Ping a nonexistent node should return pang
    Result = hornbeam_dist:ping('nonexistent@nowhere'),
    ?assertEqual(pang, Result).

test_rpc_call_local(_Config) ->
    %% RPC call to local node
    Node = hornbeam_dist:node(),

    %% Call erlang:node/0 on local node
    {ok, Result} = hornbeam_dist:rpc_call(Node, erlang, node, [], 5000),
    ?assertEqual(Node, Result),

    %% Call lists:reverse/1
    {ok, Reversed} = hornbeam_dist:rpc_call(Node, lists, reverse, [[1, 2, 3]], 5000),
    ?assertEqual([3, 2, 1], Reversed),

    %% Call erlang:+/2 via apply
    {ok, Sum} = hornbeam_dist:rpc_call(Node, erlang, '+', [10, 20], 5000),
    ?assertEqual(30, Sum).

test_rpc_call_error(_Config) ->
    %% RPC call to nonexistent node should return error
    {error, Reason} = hornbeam_dist:rpc_call('nonexistent@nowhere', erlang, node, [], 1000),
    ?assert(Reason =/= undefined).

test_rpc_cast_local(_Config) ->
    %% RPC cast should return ok immediately
    Node = hornbeam_dist:node(),

    %% Create a process to receive a message
    Self = self(),
    Pid = spawn(fun() ->
        receive
            {cast_test, Value} ->
                Self ! {received, Value}
        after 5000 ->
            Self ! timeout
        end
    end),

    %% Cast to send a message (erlang:send/2)
    ok = hornbeam_dist:rpc_cast(Node, erlang, send, [Pid, {cast_test, hello}]),

    %% Verify message was received
    receive
        {received, hello} -> ok;
        timeout -> ct:fail("Cast did not execute")
    after 2000 ->
        ct:fail("Did not receive cast result")
    end.

test_atom_conversion(_Config) ->
    %% Test that atom inputs work
    Node = hornbeam_dist:node(),
    {ok, _} = hornbeam_dist:rpc_call(Node, erlang, node, [], 5000),

    %% ping with atom
    pang = hornbeam_dist:ping(nonexistent_node).

test_binary_conversion(_Config) ->
    %% Test that binary inputs are converted to atoms
    Node = hornbeam_dist:node(),
    NodeBin = atom_to_binary(Node, utf8),

    %% RPC call with binary node name
    {ok, Result} = hornbeam_dist:rpc_call(NodeBin, <<"erlang">>, <<"node">>, [], 5000),
    ?assertEqual(Node, Result),

    %% ping with binary
    pang = hornbeam_dist:ping(<<"nonexistent_node">>).

test_list_conversion(_Config) ->
    %% Test that list inputs are converted to atoms
    Node = hornbeam_dist:node(),
    NodeList = atom_to_list(Node),

    %% RPC call with list node name
    {ok, Result} = hornbeam_dist:rpc_call(NodeList, "erlang", "node", [], 5000),
    ?assertEqual(Node, Result).
