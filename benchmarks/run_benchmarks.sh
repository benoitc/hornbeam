#!/bin/bash
# Hornbeam FD Reactor Benchmark Runner
#
# This script runs benchmarks comparing NIF vs FD Reactor modes.
#
# Prerequisites:
# - wrk (HTTP benchmarking tool)
# - Erlang/OTP
# - hornbeam compiled
#
# Usage:
#   ./run_benchmarks.sh [scenario]
#
# Examples:
#   ./run_benchmarks.sh           # Run all scenarios
#   ./run_benchmarks.sh simple_get # Run specific scenario

set -e

cd "$(dirname "$0")/.."

# Check for wrk
if ! command -v wrk &> /dev/null; then
    echo "Error: wrk is not installed"
    echo "Install with: brew install wrk (macOS) or apt install wrk (Linux)"
    exit 1
fi

# Compile if needed
echo "Compiling hornbeam..."
rebar3 compile

# Add scenarios to Python path
export PYTHONPATH="$PWD/benchmarks:$PYTHONPATH"

# Run benchmarks
echo "Running benchmarks..."
if [ -n "$1" ]; then
    erl -pa _build/default/lib/*/ebin \
        -noshell \
        -eval "fd_reactor_benchmark:run($1)" \
        -s init stop
else
    erl -pa _build/default/lib/*/ebin \
        -noshell \
        -eval "fd_reactor_benchmark:run_all()" \
        -s init stop
fi

echo "Done!"
