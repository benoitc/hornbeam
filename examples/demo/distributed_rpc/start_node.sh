#!/bin/bash
# Distributed RPC Demo - Node Startup Script
#
# Starts an Erlang node and optionally connects to other nodes in the cluster.
# Environment variables:
#   NODE_NAME - Name for this node (default: node@hostname)
#   COOKIE - Erlang cookie for cluster auth (default: demo_cluster)
#   CONNECT_TO - Comma-separated list of nodes to connect to
#   IS_MAIN - If "true", start the HTTP server

set -e

# Default values
NODE_NAME="${NODE_NAME:-node@$(hostname)}"
COOKIE="${COOKIE:-demo_cluster}"
IS_MAIN="${IS_MAIN:-false}"

echo "Starting node: $NODE_NAME"
echo "Cookie: $COOKIE"
echo "Is main: $IS_MAIN"

# Build the Erlang command (use -sname for short names within Docker network)
# Include both hornbeam libs and the demo's inference module
ERL_CMD="erl -sname $NODE_NAME -setcookie $COOKIE -pa /build/hornbeam/_build/default/lib/*/ebin -pa /build/hornbeam/examples/demo/distributed_rpc/ebin"

# Add connection commands if CONNECT_TO is set
if [ -n "$CONNECT_TO" ]; then
    echo "Will connect to: $CONNECT_TO"
    # Wait for other nodes to be ready
    sleep 3
fi

if [ "$IS_MAIN" = "true" ]; then
    # Main node: start hornbeam and serve HTTP
    exec $ERL_CMD -noshell -eval "
        application:ensure_all_started(hornbeam),
        % Connect to other nodes
        ConnectTo = string:tokens(\"${CONNECT_TO}\", \",\"),
        lists:foreach(fun(Node) ->
            NodeAtom = list_to_atom(Node),
            io:format(\"Connecting to ~p~n\", [NodeAtom]),
            case net_adm:ping(NodeAtom) of
                pong -> io:format(\"Connected to ~p~n\", [NodeAtom]);
                pang -> io:format(\"Failed to connect to ~p~n\", [NodeAtom])
            end
        end, ConnectTo),
        % Start HTTP server
        hornbeam:start(\"app:app\", #{
            bind => <<\"[::]:8000\">>,
            worker_class => asgi,
            pythonpath => [\"/build/hornbeam/examples/demo/distributed_rpc\"]
        }),
        io:format(\"Hornbeam started on port 8000~n\", []),
        receive stop -> ok end.
    "
else
    # Worker node: just stay connected
    exec $ERL_CMD -noshell -eval "
        application:ensure_all_started(hornbeam),
        io:format(\"Worker node ready: ~p~n\", [node()]),
        receive stop -> ok end.
    "
fi
