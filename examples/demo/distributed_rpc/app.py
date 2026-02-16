# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""Distributed RPC Demo - FastAPI + Erlang Cluster.

This example demonstrates distributed computing across Erlang nodes.
Work is automatically distributed and results are gathered.

Run standalone (simulated):
    cd examples/demo/distributed_rpc
    pip install -r requirements.txt
    uvicorn app:app --reload

Run with Hornbeam cluster:
    # Node 1 (main)
    rebar3 shell --sname main
    > hornbeam:start("app:app", #{
        worker_class => asgi,
        pythonpath => ["examples/demo/distributed_rpc"]
    }).

    # Node 2 (worker)
    rebar3 shell --sname worker
    > net_adm:ping('main@hostname').

Test:
    curl http://localhost:8000/cluster
    curl -X POST http://localhost:8000/infer \
         -H "Content-Type: application/json" \
         -d '{"prompts": ["Hello", "World", "Test"]}'
"""

from fastapi import FastAPI
from pydantic import BaseModel
import asyncio
import random

# Import hornbeam Erlang integration (with fallback)
try:
    from hornbeam_erlang import (
        rpc_call, rpc_cast, nodes as get_nodes, node as get_node,
        state_get, state_set, state_incr
    )
    USING_ERLANG = True
except ImportError:
    USING_ERLANG = False
    _state = {}

    def rpc_call(node, module, function, args, timeout_ms=5000):
        # Simulate remote call
        return {"simulated": True, "node": node, "result": f"processed: {args}"}

    def rpc_cast(node, module, function, args):
        pass

    def get_nodes():
        # Simulate some connected nodes for demo
        return ["node1@gpu", "node2@gpu", "node3@gpu"]

    def get_node():
        return "main@localhost"

    def state_get(key):
        return _state.get(key)

    def state_set(key, value):
        _state[key] = value

    def state_incr(key, delta=1):
        _state[key] = _state.get(key, 0) + delta
        return _state[key]


app = FastAPI(
    title="Distributed RPC Demo",
    description="Distribute work across Erlang cluster nodes"
)


class InferRequest(BaseModel):
    prompts: list[str]
    model: str = "default"


class InferResult(BaseModel):
    prompt: str
    node: str
    result: str
    success: bool


class InferResponse(BaseModel):
    results: list[InferResult]
    total_nodes: int
    using_erlang: bool


class ClusterStatus(BaseModel):
    local_node: str
    connected_nodes: list[str]
    node_count: int
    using_erlang: bool


class NodeInfo(BaseModel):
    name: str
    status: str
    process_count: int | None = None


@app.get("/cluster", response_model=ClusterStatus)
async def cluster_status():
    """Get cluster status - all connected Erlang nodes."""
    connected = get_nodes()
    local = get_node()

    return ClusterStatus(
        local_node=local,
        connected_nodes=connected,
        node_count=len(connected),
        using_erlang=USING_ERLANG
    )


@app.get("/nodes")
async def list_nodes():
    """List nodes with detailed status."""
    connected = get_nodes()
    node_info = []

    for n in connected:
        if USING_ERLANG:
            try:
                procs = rpc_call(n, 'erlang', 'system_info', ['process_count'])
                node_info.append(NodeInfo(name=n, status="connected", process_count=procs))
            except Exception as e:
                node_info.append(NodeInfo(name=n, status=f"error: {e}"))
        else:
            # Simulated status
            node_info.append(NodeInfo(
                name=n,
                status="connected (simulated)",
                process_count=random.randint(100, 500)
            ))

    return {"nodes": node_info, "using_erlang": USING_ERLANG}


@app.post("/infer", response_model=InferResponse)
async def distributed_inference(request: InferRequest):
    """Distribute inference across GPU nodes.

    Prompts are distributed round-robin across available nodes.
    Results are gathered and returned together.
    """
    state_incr("infer_requests")

    gpu_nodes = get_nodes()
    if not gpu_nodes:
        # Fallback to local processing
        state_incr("local_fallback")
        return InferResponse(
            results=[
                InferResult(
                    prompt=p,
                    node="local",
                    result=f"processed locally: {p}",
                    success=True
                )
                for p in request.prompts
            ],
            total_nodes=0,
            using_erlang=USING_ERLANG
        )

    # Distribute prompts across nodes
    results = []
    for i, prompt in enumerate(request.prompts):
        node = gpu_nodes[i % len(gpu_nodes)]

        if USING_ERLANG:
            try:
                result = rpc_call(
                    node, "inference", "generate",
                    [request.model, prompt],
                    timeout_ms=30000
                )
                results.append(InferResult(
                    prompt=prompt,
                    node=node,
                    result=str(result),
                    success=True
                ))
                state_incr("rpc_success")
            except Exception as e:
                results.append(InferResult(
                    prompt=prompt,
                    node=node,
                    result=f"error: {e}",
                    success=False
                ))
                state_incr("rpc_error")
        else:
            # Simulate distributed processing
            await asyncio.sleep(0.01)  # Simulate network latency
            results.append(InferResult(
                prompt=prompt,
                node=node,
                result=f"[{node}] generated response for: {prompt[:20]}...",
                success=True
            ))

    return InferResponse(
        results=results,
        total_nodes=len(gpu_nodes),
        using_erlang=USING_ERLANG
    )


@app.get("/")
async def root():
    """Service info."""
    return {
        "service": "Distributed RPC Demo",
        "endpoints": {
            "GET /cluster": "View cluster status",
            "GET /nodes": "List nodes with details",
            "POST /infer": "Distribute inference across nodes"
        },
        "using_erlang": USING_ERLANG,
        "note": "No Redis. No RabbitMQ. Just Erlang."
    }
