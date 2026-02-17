#!/usr/bin/env python3
"""
Compare ASGI server performance: Hornbeam vs Uvicorn vs Granian vs Gunicorn.

This script runs the same benchmarks against all four ASGI servers and provides
a side-by-side comparison of the results.

Usage:
    python compare_asgi_servers.py
    python compare_asgi_servers.py --output comparison.json
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
VENV_DIR = BENCHMARK_DIR / '.venv'
REQUIREMENTS = BENCHMARK_DIR / 'requirements.txt'

WORKERS = 4


def setup_venv():
    """Setup virtual environment and install dependencies if needed."""
    if not VENV_DIR.exists():
        print("Creating virtual environment...")
        subprocess.run([sys.executable, '-m', 'venv', str(VENV_DIR)], check=True)

    pip = VENV_DIR / 'bin' / 'pip'
    python = VENV_DIR / 'bin' / 'python'

    # Check if dependencies are installed
    result = subprocess.run(
        [str(pip), 'freeze'],
        capture_output=True,
        text=True,
        check=False
    )
    installed = result.stdout.lower()

    needs_install = False
    for pkg in ['uvicorn', 'granian', 'gunicorn', 'uvloop']:
        if pkg not in installed:
            needs_install = True
            break

    if needs_install:
        print("Installing dependencies...")
        subprocess.run(
            [str(pip), 'install', '-r', str(REQUIREMENTS)],
            check=True,
            capture_output=True
        )
        print("Dependencies installed.")

    return python


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


def start_hornbeam(bind):
    """Start hornbeam server in ASGI mode."""
    erl_cmd = f'''
        code:add_pathsz(filelib:wildcard("_build/default/lib/*/ebin")),
        application:ensure_all_started(hornbeam),
        hornbeam:start("simple_asgi_app:application", #{{
            bind => <<"{bind}">>,
            worker_class => asgi,
            workers => {WORKERS},
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


def stop_server(proc):
    """Stop a server process."""
    if proc:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def start_uvicorn(bind, python):
    """Start uvicorn server with uvloop."""
    host, port = bind.split(':')
    cmd = [
        str(python), '-m', 'uvicorn',
        '--host', host,
        '--port', port,
        '--workers', str(WORKERS),
        '--loop', 'uvloop',
        '--no-access-log',
        'simple_asgi_app:application',
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=BENCHMARK_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(3)
    return proc


def start_granian(bind, python):
    """Start granian server."""
    host, port = bind.split(':')
    cmd = [
        str(VENV_DIR / 'bin' / 'granian'),
        '--host', host,
        '--port', port,
        '--workers', str(WORKERS),
        '--interface', 'asgi',
        '--loop', 'uvloop',
        'simple_asgi_app:application',
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=BENCHMARK_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(3)
    return proc


def start_gunicorn(bind, python):
    """Start gunicorn server with uvicorn workers (ASGI)."""
    cmd = [
        str(python), '-m', 'gunicorn',
        '--worker-class', 'uvicorn.workers.UvicornWorker',
        '--workers', str(WORKERS),
        '--bind', bind,
        '--access-logfile', '/dev/null',
        '--error-logfile', '/dev/null',
        '--log-level', 'warning',
        'simple_asgi_app:application',
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=BENCHMARK_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(3)
    return proc


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


def print_comparison(all_results):
    """Print side-by-side comparison."""
    servers = ['hornbeam', 'uvicorn', 'granian', 'gunicorn']
    available_servers = [s for s in servers if s in all_results and all_results[s]]

    if not available_servers:
        print("No results to compare.")
        return

    # Get hornbeam as baseline
    baseline = 'hornbeam' if 'hornbeam' in available_servers else available_servers[0]

    print("\n" + "=" * 100)
    print("ASGI SERVER COMPARISON (4 workers, uvloop)")
    print("=" * 100)

    # Header
    header = f"{'Test':<20}"
    for server in available_servers:
        header += f"{server.upper():<20}"
    print(header)
    print("-" * 100)

    # Get all test names
    test_names = set()
    for server in available_servers:
        test_names.update(all_results[server].keys())

    for test in sorted(test_names):
        row = f"{test:<20}"
        baseline_rps = all_results.get(baseline, {}).get(test, {}).get('requests_per_sec', 0)

        for server in available_servers:
            rps = all_results.get(server, {}).get(test, {}).get('requests_per_sec', 0)
            if rps:
                if server == baseline or not baseline_rps:
                    row += f"{rps:<20.1f}"
                else:
                    diff = ((rps - baseline_rps) / baseline_rps) * 100
                    row += f"{rps:.1f} ({diff:+.1f}%)".ljust(20)
            else:
                row += f"{'N/A':<20}"
        print(row)

    print("-" * 100)
    print(f"Baseline: {baseline.upper()}")


def main():
    parser = argparse.ArgumentParser(description='Compare ASGI servers: Hornbeam vs Uvicorn vs Granian vs Gunicorn')
    parser.add_argument('--bind', default='127.0.0.1:8765', help='Bind address')
    parser.add_argument('--output', help='Output JSON file')
    parser.add_argument('--skip-hornbeam', action='store_true', help='Skip hornbeam benchmark')
    parser.add_argument('--skip-uvicorn', action='store_true', help='Skip uvicorn benchmark')
    parser.add_argument('--skip-granian', action='store_true', help='Skip granian benchmark')
    parser.add_argument('--skip-gunicorn', action='store_true', help='Skip gunicorn benchmark')
    args = parser.parse_args()

    tool = check_dependencies()
    print(f"Using benchmark tool: {tool}")
    print(f"Workers: {WORKERS}")

    # Setup venv for Python servers
    python = setup_venv()

    all_results = {}

    # Benchmark Hornbeam
    if not args.skip_hornbeam:
        print("\nBenchmarking HORNBEAM (ASGI)...")
        proc = start_hornbeam(args.bind)
        try:
            all_results['hornbeam'] = run_benchmark_suite(tool, args.bind)
        finally:
            stop_server(proc)
        time.sleep(2)

    # Benchmark Uvicorn
    if not args.skip_uvicorn:
        print("\nBenchmarking UVICORN (uvloop)...")
        proc = start_uvicorn(args.bind, python)
        try:
            all_results['uvicorn'] = run_benchmark_suite(tool, args.bind)
        finally:
            stop_server(proc)
        time.sleep(2)

    # Benchmark Granian
    if not args.skip_granian:
        print("\nBenchmarking GRANIAN (uvloop)...")
        proc = start_granian(args.bind, python)
        try:
            all_results['granian'] = run_benchmark_suite(tool, args.bind)
        finally:
            stop_server(proc)
        time.sleep(2)

    # Benchmark Gunicorn
    if not args.skip_gunicorn:
        print("\nBenchmarking GUNICORN (UvicornWorker)...")
        proc = start_gunicorn(args.bind, python)
        try:
            all_results['gunicorn'] = run_benchmark_suite(tool, args.bind)
        finally:
            stop_server(proc)

    # Print comparison
    print_comparison(all_results)

    if args.output:
        with open(args.output, 'w') as f:
            json.dump(all_results, f, indent=2)
        print(f"\nResults saved to {args.output}")


if __name__ == '__main__':
    main()
