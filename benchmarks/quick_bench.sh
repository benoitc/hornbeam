#!/bin/bash
# Quick benchmark for hornbeam WSGI server

set -e

cd "$(dirname "$0")/.."

# Check if ab is available
if ! command -v ab &> /dev/null; then
    echo "Error: 'ab' (Apache Bench) not found."
    echo "  macOS: brew install httpd (or use 'ab' from system)"
    echo "  Linux: apt-get install apache2-utils"
    exit 1
fi

# Check if project is compiled
if [ ! -d "_build/default/lib" ]; then
    echo "Compiling hornbeam..."
    rebar3 compile
fi

echo "Starting hornbeam with WSGI worker..."

# Start hornbeam in background
erl -pa _build/default/lib/*/ebin \
    -noshell \
    -eval '
        application:ensure_all_started(hornbeam),
        hornbeam:start("simple_app:application", #{
            bind => <<"127.0.0.1:8765">>,
            worker_class => wsgi,
            pythonpath => [<<"benchmarks">>]
        }).
    ' &

HORNBEAM_PID=$!

# Wait for server to be ready
echo "Waiting for server to start..."
sleep 4

# Verify server is running
for i in {1..10}; do
    if curl -s http://127.0.0.1:8765/ > /dev/null 2>&1; then
        echo "Server is ready!"
        break
    fi
    sleep 0.5
done

echo ""
echo "=== Benchmark: Simple requests (10000 requests, 100 concurrent) ==="
ab -n 10000 -c 100 -k http://127.0.0.1:8765/ 2>&1 | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""
echo "=== Benchmark: High concurrency (5000 requests, 500 concurrent) ==="
ab -n 5000 -c 500 -k http://127.0.0.1:8765/ 2>&1 | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""
echo "=== Benchmark: Large response (1000 requests, 50 concurrent) ==="
ab -n 1000 -c 50 -k http://127.0.0.1:8765/large 2>&1 | grep -E "(Requests per second|Time per request|Failed requests)"

echo ""
echo "Stopping hornbeam..."
kill $HORNBEAM_PID 2>/dev/null || true
wait $HORNBEAM_PID 2>/dev/null || true

echo "Done!"
