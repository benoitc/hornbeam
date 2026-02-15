"""Hooks demo Python module.

Demonstrates hornbeam hooks with both synchronous and asyncio patterns.
Uses erlang-python's reentrant callbacks for transparent Python↔Erlang calls.

Usage:
    # Start Erlang shell with hornbeam
    rebar3 shell

    # In Erlang shell:
    hooks_demo:start().
    hooks_demo:demo_sync().
    hooks_demo:demo_async().
    hooks_demo:demo_nested().
"""

import asyncio
import time
from typing import Any, Dict, List

# Import hornbeam's Erlang integration
from hornbeam_erlang import execute, execute_async, await_result


# =============================================================================
# Configuration (called by Erlang hooks)
# =============================================================================

_config: Dict[str, Any] = {
    "multiplier": 10,
    "batch_size": 100,
    "model_name": "demo-model",
}


def get_config(key: str) -> Any:
    """Get configuration value.

    This function is called by Erlang via py:call() during hook execution,
    demonstrating that reentrant callbacks work correctly.
    """
    return _config.get(key, None)


def set_config(key: str, value: Any) -> None:
    """Set configuration value."""
    _config[key] = value


# =============================================================================
# Computation functions (called by Erlang hooks)
# =============================================================================

def compute_product(numbers: List[int]) -> int:
    """Compute product of numbers.

    Called by Erlang's handle_compute(<<"product">>, ...) which itself
    is called from Python via execute(). Demonstrates reentrant callbacks.
    """
    result = 1
    for n in numbers:
        result *= n
    return result


def process_data(data: Any) -> Dict[str, Any]:
    """Process data and return result.

    Called by Erlang's handle_data(<<"process">>, ...).
    """
    return {
        "original": data,
        "processed": True,
        "length": len(str(data)),
    }


# =============================================================================
# Synchronous Hook Tests
# =============================================================================

def test_sync_hooks() -> Dict[str, Any]:
    """Test synchronous hook execution.

    Demonstrates:
    1. Python calling Erlang hook (execute)
    2. Erlang hook calling Python (py:call)
    3. Results flowing back correctly
    """
    results = {}

    # Test 1: Simple sum (Erlang handles computation)
    # Flow: Python -> execute -> Erlang handle_compute -> Result
    sum_result = execute("compute", "sum", 1, 2, 3, 4, 5)
    results["sum_result"] = sum_result

    # Test 2: Product with callback (Erlang calls Python)
    # Flow: Python -> execute -> Erlang handle_compute -> py:call compute_product -> Result
    product_result = execute("compute", "product", [1, 2, 3, 4])
    results["product_result"] = product_result

    return results


# =============================================================================
# Async Hook Tests
# =============================================================================

def test_async_hooks() -> Dict[str, Any]:
    """Test concurrent hook execution using execute_async.

    Uses execute_async() to dispatch multiple calls concurrently, then
    await_result() to collect results. This works because execute_async
    posts requests to Erlang from the main worker thread.
    """
    results = {}

    # Sequential execution (baseline)
    start = time.time()
    seq_results = []
    for i in range(3):
        result = execute("data", "process", f"item_{i}", delay=50)
        seq_results.append(result)
    seq_time = (time.time() - start) * 1000

    # Concurrent execution using execute_async + await_result
    start = time.time()

    # Dispatch all requests concurrently (non-blocking)
    refs = [
        execute_async("data", "process", f"item_{i}", delay=50)
        for i in range(3)
    ]

    # Collect results (each await_result blocks until that result is ready)
    conc_results = [await_result(ref) for ref in refs]
    conc_time = (time.time() - start) * 1000

    results["sequential_results"] = seq_results
    results["concurrent_results"] = conc_results
    results["sequential_time"] = seq_time
    results["concurrent_time"] = conc_time
    results["speedup"] = seq_time / conc_time if conc_time > 0 else 0

    return results


# =============================================================================
# Async with asyncio (for ASGI apps)
# =============================================================================

async def async_execute(app_path: str, action: str, *args, **kwargs) -> Any:
    """Execute hook asynchronously using asyncio.

    For use in ASGI applications (FastAPI, Starlette, etc.) where you want
    to avoid blocking the event loop.

    Note: This uses execute_async + await_result under the hood, dispatching
    via the worker thread that has the callback context.
    """
    # Dispatch the async request (non-blocking, returns a reference)
    ref = execute_async(app_path, action, *args, **kwargs)

    # Use asyncio to poll for results without blocking
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, lambda: await_result(ref))


async def demo_asyncio_hooks() -> Dict[str, Any]:
    """Demo using hooks with asyncio.

    This pattern is useful in FastAPI/ASGI applications:

    @app.post("/process")
    async def process_endpoint(data: Data):
        # Non-blocking hook execution
        result = await async_execute("compute", "sum", *data.numbers)
        return {"result": result}
    """
    # Dispatch all requests first (non-blocking)
    refs = [
        execute_async("compute", "sum", i, i+1, i+2)
        for i in range(5)
    ]

    # Await all results concurrently
    loop = asyncio.get_event_loop()
    tasks = [
        loop.run_in_executor(None, lambda r=ref: await_result(r))
        for ref in refs
    ]
    results = await asyncio.gather(*tasks)

    return {
        "async_results": list(results),
        "expected": [3, 6, 9, 12, 15],  # 0+1+2, 1+2+3, etc.
    }


# =============================================================================
# Nested Callbacks Test
# =============================================================================

def nested_continue(n: int, depth: int) -> int:
    """Continue the nested callback chain.

    Called by Erlang's handle_data(<<"nested_step">>, ...) which itself
    was called from Python. Creates a deep nesting pattern:

    Python (test_nested) -> Erlang (nested_step) -> Python (nested_continue)
                         -> Erlang (nested_step) -> Python (nested_continue)
                         -> ... until depth reaches 0
    """
    if depth <= 0:
        return n

    # Call Erlang hook which will call us back
    return execute("data", "nested_step", n, depth)


def test_nested(depth: int = 5) -> int:
    """Test deeply nested Python↔Erlang callbacks.

    Creates depth levels of alternating Python and Erlang calls:
    Python -> Erlang -> Python -> Erlang -> ... -> Result

    With reentrant callbacks, this works without deadlocking.
    """
    return execute("data", "nested_step", 0, depth)


# =============================================================================
# Example ASGI Application Pattern
# =============================================================================

# This shows how hooks would be used in a real FastAPI application:

"""
from fastapi import FastAPI
from hooks_demo_py import async_execute

app = FastAPI()

@app.post("/compute/sum")
async def compute_sum(numbers: list[int]):
    # Uses hooks to call Erlang, which may call back to Python
    result = await async_execute("compute", "sum", *numbers)
    return {"sum": result}

@app.post("/compute/product")
async def compute_product(numbers: list[int]):
    # This demonstrates reentrant callbacks:
    # FastAPI (Python) -> execute -> Erlang hook -> py:call -> Python
    result = await async_execute("compute", "product", numbers)
    return {"product": result}

@app.get("/config/{key}")
async def get_config_endpoint(key: str):
    # Nested callback: Python -> Erlang -> Python (get_config)
    result = await async_execute("compute", "with_config", 10)
    return {"result": result, "config_key": key}
"""


# =============================================================================
# CLI Testing
# =============================================================================

if __name__ == "__main__":
    # For testing outside of Erlang (mocked execute)
    print("This module is designed to run within hornbeam/Erlang.")
    print("Start with: rebar3 shell")
    print("Then run: hooks_demo:start().")
