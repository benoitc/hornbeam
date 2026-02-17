#!/usr/bin/env python3
"""
Compare hornbeam vs gunicorn performance.

This script runs the same benchmarks against both servers and provides
a side-by-side comparison of the results.

Usage:
    python compare_servers.py
    python compare_servers.py --output comparison.json
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
GUNICORN_BENCHMARKS = Path.home() / 'Projects' / 'gunicorn' / 'benchmarks'


def check_dependencies():
    """Check if required tools are available."""
    for tool in ['wrk', 'ab']:
        try:
            subprocess.run([tool, '--version'], capture_output=True, check=False)
            return tool
        except FileNotFoundError:
            continue
    print("Error: Neither 'wrk' nor 'ab' found.")
    sys.exit(1)


def start_gunicorn(bind):
    """Start gunicorn server."""
    if not GUNICORN_BENCHMARKS.exists():
        print(f"Warning: Gunicorn benchmarks not found at {GUNICORN_BENCHMARKS}")
        return None

    cmd = [
        sys.executable, '-m', 'gunicorn',
        '--worker-class', 'gthread',
        '--workers', '2',
        '--threads', '4',
        '--worker-connections', '1000',
        '--bind', bind,
        '--access-logfile', '/dev/null',
        '--error-logfile', '/dev/null',
        '--log-level', 'warning',
        'simple_app:application',
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=GUNICORN_BENCHMARKS,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(2)
    return proc


def stop_gunicorn(proc):
    """Stop gunicorn server."""
    if proc:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def start_hornbeam(bind):
    """Start hornbeam server."""
    erl_cmd = f'''
        code:add_pathsz(filelib:wildcard("_build/default/lib/*/ebin")),
        application:ensure_all_started(hornbeam),
        hornbeam:start("simple_app:application", #{{
            bind => <<"{bind}">>,
            worker_class => wsgi,
            pythonpath => [<<"benchmarks">>]
        }}).
    '''

    cmd = [
        'erl',
        '-noshell',
        '-eval', erl_cmd.strip().replace('\n', ' '),
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(4)
    return proc


def stop_hornbeam(proc):
    """Stop hornbeam server."""
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def run_ab_benchmark(url, requests, concurrency):
    """Run Apache Bench benchmark."""
    cmd = ['ab', '-n', str(requests), '-c', str(concurrency), '-k', url]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)

    metrics = {}
    for line in result.stdout.split('\n'):
        if 'Requests per second' in line:
            metrics['requests_per_sec'] = float(line.split(':')[1].split()[0])
        elif 'Time per request' in line and 'mean' in line:
            metrics['latency_avg'] = line.split(':')[1].strip()
        elif 'Failed requests' in line:
            metrics['failed_requests'] = int(line.split(':')[1].strip())
    return metrics


def run_wrk_benchmark(url, duration, threads, connections):
    """Run wrk benchmark."""
    cmd = ['wrk', '-t', str(threads), '-c', str(connections), '-d', f'{duration}s', '--latency', url]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)

    metrics = {}
    for line in result.stdout.split('\n'):
        if 'Requests/sec' in line:
            metrics['requests_per_sec'] = float(line.split(':')[1].strip())
        elif 'Latency' in line and 'Distribution' not in line:
            parts = line.split()
            if len(parts) >= 2:
                metrics['latency_avg'] = parts[1]
    return metrics


def run_benchmark_suite(tool, bind):
    """Run benchmark suite."""
    results = {}
    configs = [
        {'name': 'simple', 'path': '/', 'connections': 100, 'requests': 10000},
        {'name': 'high_concurrency', 'path': '/', 'connections': 500, 'requests': 5000},
        {'name': 'large_response', 'path': '/large', 'connections': 50, 'requests': 1000},
    ]

    for config in configs:
        url = f'http://{bind}{config["path"]}'
        print(f"    {config['name']}...", end=' ', flush=True)

        if tool == 'wrk':
            metrics = run_wrk_benchmark(url, 10, 4, config['connections'])
        else:
            metrics = run_ab_benchmark(url, config['requests'], config['connections'])

        results[config['name']] = metrics
        print(f"{metrics.get('requests_per_sec', 'N/A')} req/s")

    return results


def print_comparison(gunicorn_results, hornbeam_results):
    """Print side-by-side comparison."""
    print("\n" + "=" * 70)
    print("COMPARISON: GUNICORN vs HORNBEAM")
    print("=" * 70)
    print(f"{'Test':<20} {'Gunicorn (req/s)':<20} {'Hornbeam (req/s)':<20} {'Diff':<10}")
    print("-" * 70)

    for test in gunicorn_results.keys():
        g_rps = gunicorn_results.get(test, {}).get('requests_per_sec', 0)
        h_rps = hornbeam_results.get(test, {}).get('requests_per_sec', 0)

        if g_rps and h_rps:
            diff = ((h_rps - g_rps) / g_rps) * 100
            diff_str = f"{diff:+.1f}%"
        else:
            diff_str = "N/A"

        print(f"{test:<20} {g_rps:<20.1f} {h_rps:<20.1f} {diff_str:<10}")


def main():
    parser = argparse.ArgumentParser(description='Compare hornbeam vs gunicorn')
    parser.add_argument('--bind', default='127.0.0.1:8765', help='Bind address')
    parser.add_argument('--output', help='Output JSON file')
    args = parser.parse_args()

    tool = check_dependencies()
    print(f"Using benchmark tool: {tool}")

    all_results = {}

    # Benchmark gunicorn
    print("\nBenchmarking GUNICORN...")
    gunicorn_proc = start_gunicorn(args.bind)
    if gunicorn_proc:
        try:
            all_results['gunicorn'] = run_benchmark_suite(tool, args.bind)
        finally:
            stop_gunicorn(gunicorn_proc)
    else:
        print("  Skipped (not available)")
        all_results['gunicorn'] = {}

    # Small pause between servers
    time.sleep(2)

    # Benchmark hornbeam
    print("\nBenchmarking HORNBEAM...")
    hornbeam_proc = start_hornbeam(args.bind)
    try:
        all_results['hornbeam'] = run_benchmark_suite(tool, args.bind)
    finally:
        stop_hornbeam(hornbeam_proc)

    # Print comparison
    if all_results['gunicorn']:
        print_comparison(all_results['gunicorn'], all_results['hornbeam'])

    if args.output:
        with open(args.output, 'w') as f:
            json.dump(all_results, f, indent=2)
        print(f"\nResults saved to {args.output}")


if __name__ == '__main__':
    main()
