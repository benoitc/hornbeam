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

%%% @doc Example: Distributed Hornbeam with RPC
%%%
%%% This module demonstrates running hornbeam in a distributed Erlang
%%% cluster, allowing Python apps to call functions on remote nodes.
%%%
%%% == Quick Start ==
%%%
%%% Terminal 1 (Web server):
%%% ```
%%% $ rebar3 shell --sname web
%%% > distributed_rpc_example:start_web().
%%% '''
%%%
%%% Terminal 2 (Worker node):
%%% ```
%%% $ rebar3 shell --sname worker
%%% > distributed_rpc_example:start_worker().
%%% > net_adm:ping('web@yourhost').
%%% '''
%%%
%%% Test:
%%% ```
%%% $ curl http://localhost:8000/cluster
%%% $ curl http://localhost:8000/nodes
%%% $ curl -X POST http://localhost:8000/rpc \
%%%        -H "Content-Type: application/json" \
%%%        -d '{"node": "worker@yourhost", "module": "erlang",
%%%             "function": "system_info", "args": ["process_count"]}'
%%% '''
-module(distributed_rpc_example).

-export([
    start_web/0,
    start_worker/0,
    register_functions/0
]).

%% @doc Start the web server node.
%% This node runs hornbeam and accepts HTTP requests.
start_web() ->
    %% Register Erlang callbacks for Python to use
    register_functions(),

    %% Start hornbeam with the distributed RPC example app
    hornbeam:start("app:application", #{
        bind => <<"0.0.0.0:8000">>,
        pythonpath => [<<"examples/distributed_rpc">>]
    }).

%% @doc Start a worker node.
%% Worker nodes process distributed work (ML inference, etc.).
start_worker() ->
    %% Register the ML worker module for remote calls
    register_ml_worker().

%% @doc Register Erlang functions callable from Python.
register_functions() ->
    %% These can be called via hornbeam_erlang.call('function_name', args)
    hornbeam:register_function(get_node_info, fun([]) ->
        #{
            node => atom_to_binary(node(), utf8),
            connected => [atom_to_binary(N, utf8) || N <- nodes()],
            uptime => element(1, erlang:statistics(wall_clock))
        }
    end),

    hornbeam:register_function(distributed_call, fun([Node, Mod, Fun, Args]) ->
        NodeAtom = binary_to_atom(Node, utf8),
        ModAtom = binary_to_atom(Mod, utf8),
        FunAtom = binary_to_atom(Fun, utf8),
        case rpc:call(NodeAtom, ModAtom, FunAtom, Args, 5000) of
            {badrpc, Reason} -> #{error => Reason};
            Result -> #{ok => Result}
        end
    end).

%% Internal: Register ML worker functions
register_ml_worker() ->
    %% This simulates an ML inference function
    %% In production, this would call actual ML models
    erlang:register(ml_worker, self()),

    %% Export functions for RPC
    ok.

%% @doc Example ML inference function (would be on worker node).
%% Called via rpc:call(WorkerNode, ml_worker, inference, [Model, Input]).
-export([inference/2]).

inference(ModelName, Input) when is_binary(ModelName), is_binary(Input) ->
    %% Simulate ML inference
    %% In production: call Python ML model, use GPU, etc.
    timer:sleep(100),  % Simulate processing
    #{
        model => ModelName,
        input => Input,
        output => <<"embedded_", Input/binary>>,
        node => atom_to_binary(node(), utf8)
    };
inference(ModelName, Input) ->
    inference(
        ensure_binary(ModelName),
        ensure_binary(Input)
    ).

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
ensure_binary(V) -> list_to_binary(io_lib:format("~p", [V])).
