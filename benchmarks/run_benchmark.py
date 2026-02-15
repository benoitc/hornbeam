#!/usr/bin/env python3
"""
Benchmark script for hornbeam WSGI/ASGI server.

This script runs various benchmarks against hornbeam and reports performance metrics.
Requires: wrk or ab for load testing.

Usage:
    python run_benchmark.py                    # Run WSGI benchmarks
    python run_benchmark.py --asgi             # Run ASGI benchmarks
    python run_benchmark.py --output results.json  # Save results to file
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


BENCHMARK_DIR = Path(__file__).parent
PROJECT_ROOT = BENCHMARK_DIR.parent


def check_dependencies():
    """Check if required tools are available."""
    # Check for wrk (preferred) or ab
    for tool in ['wrk', 'ab']:
        try:
            subprocess.run([tool, '--version'], capture_output=True, check=False)
            return tool
        except FileNotFoundError:
            continue
    print("Error: Neither 'wrk' nor 'ab' found. Install one of them.")
    print("  macOS: brew install wrk")
    print("  Linux: apt-get install wrk (or apache2-utils for ab)")
    sys.exit(1)


def check_erlang():
    """Check if Erlang/rebar3 is available."""
    try:
        subprocess.run(['rebar3', 'version'], capture_output=True, check=True, cwd=PROJECT_ROOT)
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        print("Error: 'rebar3' not found or project not compiled.")
        print("  Run 'rebar3 compile' first.")
        sys.exit(1)


def start_hornbeam(worker_class, bind):
    """Start hornbeam server and return the process."""
    app_module = 'simple_app:application' if worker_class == 'wsgi' else 'simple_asgi_app:application'

    # Build the Erlang command
    erl_cmd = f'''
        application:ensure_all_started(hornbeam),
        hornbeam:start("{app_module}", #{{
            bind => <<"{bind}">>,
            worker_class => {worker_class},
            pythonpath => [<<"benchmarks">>]
        }}).
    '''

    cmd = [
        'erl',
        '-pa', '_build/default/lib/*/ebin',
        '-noshell',
        '-eval', erl_cmd.strip().replace('\n', ' '),
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # Wait for server to be ready (Erlang VM takes longer to boot)
    time.sleep(4)

    # Verify server is responding
    for _ in range(10):
        try:
            import urllib.request
            with urllib.request.urlopen(f'http://{bind}/') as resp:
                if resp.status == 200:
                    return proc
        except Exception:
            time.sleep(0.5)

    print("Warning: Server may not be ready, continuing anyway...")
    return proc


def stop_hornbeam(proc):
    """Stop the hornbeam server."""
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def run_wrk_benchmark(url, duration, threads, connections):
    """Run wrk benchmark and return results."""
    cmd = [
        'wrk',
        '-t', str(threads),
        '-c', str(connections),
        '-d', f'{duration}s',
        '--latency',
        url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return parse_wrk_output(result.stdout)


def run_ab_benchmark(url, requests, concurrency):
    """Run Apache Bench benchmark and return results."""
    cmd = [
        'ab',
        '-n', str(requests),
        '-c', str(concurrency),
        '-k',  # keepalive
        url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return parse_ab_output(result.stdout)


def parse_wrk_output(output):
    """Parse wrk output to extract metrics."""
    metrics = {}
    for line in output.split('\n'):
        if 'Requests/sec' in line:
            metrics['requests_per_sec'] = float(line.split(':')[1].strip())
        elif 'Transfer/sec' in line:
            metrics['transfer_per_sec'] = line.split(':')[1].strip()
        elif 'Latency' in line and 'Distribution' not in line:
            parts = line.split()
            if len(parts) >= 2:
                metrics['latency_avg'] = parts[1]
        elif '50%' in line:
            metrics['latency_p50'] = line.split()[1]
        elif '99%' in line:
            metrics['latency_p99'] = line.split()[1]
    return metrics


def parse_ab_output(output):
    """Parse ab output to extract metrics."""
    metrics = {}
    for line in output.split('\n'):
        if 'Requests per second' in line:
            metrics['requests_per_sec'] = float(line.split(':')[1].split()[0])
        elif 'Time per request' in line and 'mean' in line:
            metrics['latency_avg'] = line.split(':')[1].strip()
        elif 'Transfer rate' in line:
            metrics['transfer_per_sec'] = line.split(':')[1].strip()
        elif 'Failed requests' in line:
            metrics['failed_requests'] = int(line.split(':')[1].strip())
    return metrics


def run_benchmark_suite(tool, bind_addr):
    """Run a suite of benchmarks."""
    results = {}

    # Test configurations
    configs = [
        {'name': 'simple', 'path': '/', 'connections': 100, 'requests': 10000},
        {'name': 'high_concurrency', 'path': '/', 'connections': 500, 'requests': 5000},
        {'name': 'large_response', 'path': '/large', 'connections': 50, 'requests': 1000},
    ]

    for config in configs:
        url = f'http://{bind_addr}{config["path"]}'
        print(f"  Running {config['name']}...")

        if tool == 'wrk':
            metrics = run_wrk_benchmark(
                url,
                duration=10,
                threads=4,
                connections=config['connections'],
            )
        else:
            metrics = run_ab_benchmark(
                url,
                requests=config['requests'],
                concurrency=config['connections'],
            )

        results[config['name']] = metrics
        rps = metrics.get('requests_per_sec', 'N/A')
        print(f"    Requests/sec: {rps}")

    return results


def main():
    parser = argparse.ArgumentParser(description='Benchmark hornbeam WSGI/ASGI server')
    parser.add_argument('--bind', default='127.0.0.1:8765', help='Bind address')
    parser.add_argument('--asgi', action='store_true', help='Use ASGI worker')
    parser.add_argument('--output', help='Output JSON file for results')
    args = parser.parse_args()

    tool = check_dependencies()
    check_erlang()
    print(f"Using benchmark tool: {tool}")

    worker_class = 'asgi' if args.asgi else 'wsgi'
    all_results = {}

    print(f"\nBenchmarking hornbeam {worker_class.upper()} worker...")
    proc = start_hornbeam(
        worker_class=worker_class,
        bind=args.bind,
    )
    try:
        all_results[worker_class] = run_benchmark_suite(tool, args.bind)
    finally:
        stop_hornbeam(proc)

    # Print summary
    print("\n" + "=" * 60)
    print("BENCHMARK SUMMARY")
    print("=" * 60)
    for worker, results in all_results.items():
        print(f"\n{worker.upper()} Worker:")
        for test, metrics in results.items():
            rps = metrics.get('requests_per_sec', 'N/A')
            latency = metrics.get('latency_avg', 'N/A')
            print(f"  {test}: {rps} req/s (latency: {latency})")

    if args.output:
        with open(args.output, 'w') as f:
            json.dump(all_results, f, indent=2)
        print(f"\nResults saved to {args.output}")


if __name__ == '__main__':
    main()
