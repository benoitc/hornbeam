#!/usr/bin/env python3
"""
Benchmark different asyncio event loop implementations.

Compares: asyncio default, uvloop, and (when available) Erlang event loop.
"""

import asyncio
import time
import sys
import os

# Add priv to path for testing
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'priv'))

ITERATIONS = 100_000


async def simple_coroutine():
    """Minimal coroutine for overhead measurement."""
    return 42


async def request_simulation():
    """Simulate minimal ASGI request handling."""
    # Simulate receive
    receive_result = {'type': 'http.request', 'body': b'', 'more_body': False}
    # Simulate send
    await asyncio.sleep(0)  # Yield control like a real async app
    return receive_result


def benchmark_loop(loop_name, loop):
    """Benchmark an event loop."""
    asyncio.set_event_loop(loop)

    # Warm up
    for _ in range(1000):
        loop.run_until_complete(simple_coroutine())

    # Simple coroutine benchmark
    start = time.perf_counter()
    for _ in range(ITERATIONS):
        loop.run_until_complete(simple_coroutine())
    elapsed = time.perf_counter() - start

    simple_rate = ITERATIONS / elapsed
    print(f"{loop_name:20} simple: {simple_rate:>12,.0f} iter/s ({elapsed*1000/ITERATIONS:.4f} ms/iter)")

    # Request simulation benchmark
    start = time.perf_counter()
    for _ in range(ITERATIONS // 10):
        loop.run_until_complete(request_simulation())
    elapsed = time.perf_counter() - start

    req_rate = (ITERATIONS // 10) / elapsed
    print(f"{loop_name:20} request: {req_rate:>11,.0f} iter/s ({elapsed*1000/(ITERATIONS//10):.4f} ms/iter)")

    return simple_rate, req_rate


def main():
    print(f"Event Loop Benchmark ({ITERATIONS:,} iterations)")
    print("=" * 60)

    results = {}

    # Standard asyncio
    loop = asyncio.new_event_loop()
    results['asyncio'] = benchmark_loop("asyncio (default)", loop)
    loop.close()

    # uvloop
    try:
        import uvloop
        loop = uvloop.new_event_loop()
        results['uvloop'] = benchmark_loop("uvloop", loop)
        loop.close()
    except ImportError:
        print("uvloop not available")

    # Erlang event loop (if available)
    try:
        import erlang
        if hasattr(erlang, 'new_event_loop'):
            loop = erlang.new_event_loop()
            results['erlang'] = benchmark_loop("erlang", loop)
            # Don't close Erlang loop
    except ImportError:
        print("erlang module not available (running outside Erlang VM)")

    print()
    print("Summary:")
    print("-" * 40)

    baseline = results.get('asyncio', (1, 1))
    for name, (simple_rate, req_rate) in results.items():
        simple_speedup = simple_rate / baseline[0]
        req_speedup = req_rate / baseline[1]
        print(f"{name:15} simple: {simple_speedup:.2f}x, request: {req_speedup:.2f}x")


if __name__ == '__main__':
    main()
