#!/bin/bash
# Benchmark comparison: pooled vs non-pooled workers
#
# This script compares performance between:
# - Non-pooled: Traditional per-request Python invocation
# - Pooled: Persistent worker pool with channel-based dispatch

set -e

cd "$(dirname "$0")/.."

# Check if ab is available
if ! command -v ab &> /dev/null; then
    echo "Error: 'ab' (Apache Bench) not found."
    echo "  macOS: brew install httpd"
    echo "  Linux: apt-get install apache2-utils"
    exit 1
fi

# Check if project is compiled
if [ ! -d "_build/default/lib" ]; then
    echo "Compiling hornbeam..."
    rebar3 compile
fi

# Configuration
REQUESTS=10000
CONCURRENCY=100
PORT_NONPOOLED=8765
PORT_POOLED=8766
WORKERS=4

cleanup() {
    echo "Cleaning up..."
    kill $PID_NONPOOLED 2>/dev/null || true
    kill $PID_POOLED 2>/dev/null || true
    wait $PID_NONPOOLED 2>/dev/null || true
    wait $PID_POOLED 2>/dev/null || true
}
trap cleanup EXIT

echo "=============================================="
echo "  Hornbeam Pooled vs Non-Pooled Benchmark"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Requests: $REQUESTS"
echo "  Concurrency: $CONCURRENCY"
echo "  Workers (pooled): $WORKERS"
echo ""

# Start non-pooled server (single-app mode)
echo "Starting non-pooled server on port $PORT_NONPOOLED..."
erl -pa _build/default/lib/*/ebin \
    -noshell \
    -eval "
        application:ensure_all_started(hornbeam),
        hornbeam:start(<<\"simple_app:application\">>, #{
            bind => <<\"127.0.0.1:$PORT_NONPOOLED\">>,
            worker_class => wsgi,
            pythonpath => [<<\"benchmarks\">>]
        }).
    " > /dev/null 2>&1 &
PID_NONPOOLED=$!

# Start pooled server (multi-app mode with pool_enabled)
echo "Starting pooled server on port $PORT_POOLED..."
erl -pa _build/default/lib/*/ebin \
    -noshell \
    -eval "
        application:ensure_all_started(hornbeam),
        py:exec(<<\"import sys; sys.path.insert(0, 'benchmarks')\">>),
        hornbeam:start(#{
            bind => <<\"127.0.0.1:$PORT_POOLED\">>,
            mounts => [
                {<<\"/\">>, <<\"simple_app:application\">>, #{
                    worker_class => wsgi,
                    workers => $WORKERS,
                    pool_enabled => true,
                    timeout => 30000
                }}
            ]
        }).
    " > /dev/null 2>&1 &
PID_POOLED=$!

# Wait for servers to be ready
echo "Waiting for servers to start..."
sleep 4

# Verify servers are running
for port in $PORT_NONPOOLED $PORT_POOLED; do
    for i in {1..10}; do
        if curl -s http://127.0.0.1:$port/ > /dev/null 2>&1; then
            echo "  Server on port $port is ready"
            break
        fi
        if [ $i -eq 10 ]; then
            echo "  WARNING: Server on port $port may not be ready"
        fi
        sleep 0.5
    done
done

echo ""

# Warmup
echo "Warming up servers..."
ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_NONPOOLED/ > /dev/null 2>&1 || true
ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_POOLED/ > /dev/null 2>&1 || true
sleep 1

echo ""
echo "=============================================="
echo "  Test 1: Simple Requests ($REQUESTS req, $CONCURRENCY concurrent)"
echo "=============================================="

echo ""
echo "--- Non-Pooled ---"
RESULT_NP1=$(ab -n $REQUESTS -c $CONCURRENCY -k http://127.0.0.1:$PORT_NONPOOLED/ 2>&1)
RPS_NP1=$(echo "$RESULT_NP1" | grep "Requests per second" | awk '{print $4}')
LAT_NP1=$(echo "$RESULT_NP1" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_NP1=$(echo "$RESULT_NP1" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_NP1"
echo "  Latency:      ${LAT_NP1}ms"
echo "  Failed:       $FAIL_NP1"

echo ""
echo "--- Pooled ---"
RESULT_P1=$(ab -n $REQUESTS -c $CONCURRENCY -k http://127.0.0.1:$PORT_POOLED/ 2>&1)
RPS_P1=$(echo "$RESULT_P1" | grep "Requests per second" | awk '{print $4}')
LAT_P1=$(echo "$RESULT_P1" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_P1=$(echo "$RESULT_P1" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_P1"
echo "  Latency:      ${LAT_P1}ms"
echo "  Failed:       $FAIL_P1"

echo ""
echo "=============================================="
echo "  Test 2: High Concurrency (5000 req, 500 concurrent)"
echo "=============================================="

echo ""
echo "--- Non-Pooled ---"
RESULT_NP2=$(ab -n 5000 -c 500 -k http://127.0.0.1:$PORT_NONPOOLED/ 2>&1)
RPS_NP2=$(echo "$RESULT_NP2" | grep "Requests per second" | awk '{print $4}')
LAT_NP2=$(echo "$RESULT_NP2" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_NP2=$(echo "$RESULT_NP2" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_NP2"
echo "  Latency:      ${LAT_NP2}ms"
echo "  Failed:       $FAIL_NP2"

echo ""
echo "--- Pooled ---"
RESULT_P2=$(ab -n 5000 -c 500 -k http://127.0.0.1:$PORT_POOLED/ 2>&1)
RPS_P2=$(echo "$RESULT_P2" | grep "Requests per second" | awk '{print $4}')
LAT_P2=$(echo "$RESULT_P2" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_P2=$(echo "$RESULT_P2" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_P2"
echo "  Latency:      ${LAT_P2}ms"
echo "  Failed:       $FAIL_P2"

echo ""
echo "=============================================="
echo "  Test 3: Sustained Load (20000 req, 200 concurrent)"
echo "=============================================="

echo ""
echo "--- Non-Pooled ---"
RESULT_NP3=$(ab -n 20000 -c 200 -k http://127.0.0.1:$PORT_NONPOOLED/ 2>&1)
RPS_NP3=$(echo "$RESULT_NP3" | grep "Requests per second" | awk '{print $4}')
LAT_NP3=$(echo "$RESULT_NP3" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_NP3=$(echo "$RESULT_NP3" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_NP3"
echo "  Latency:      ${LAT_NP3}ms"
echo "  Failed:       $FAIL_NP3"

echo ""
echo "--- Pooled ---"
RESULT_P3=$(ab -n 20000 -c 200 -k http://127.0.0.1:$PORT_POOLED/ 2>&1)
RPS_P3=$(echo "$RESULT_P3" | grep "Requests per second" | awk '{print $4}')
LAT_P3=$(echo "$RESULT_P3" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_P3=$(echo "$RESULT_P3" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_P3"
echo "  Latency:      ${LAT_P3}ms"
echo "  Failed:       $FAIL_P3"

echo ""
echo "=============================================="
echo "  Summary"
echo "=============================================="
echo ""
printf "%-25s %15s %15s %10s\n" "Test" "Non-Pooled" "Pooled" "Diff"
printf "%-25s %15s %15s %10s\n" "-------------------------" "---------------" "---------------" "----------"

# Calculate differences (using awk for floating point)
if [ -n "$RPS_NP1" ] && [ -n "$RPS_P1" ]; then
    DIFF1=$(echo "$RPS_P1 $RPS_NP1" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "Simple (100 conc)" "$RPS_NP1" "$RPS_P1" "$DIFF1"
fi

if [ -n "$RPS_NP2" ] && [ -n "$RPS_P2" ]; then
    DIFF2=$(echo "$RPS_P2 $RPS_NP2" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "High conc (500 conc)" "$RPS_NP2" "$RPS_P2" "$DIFF2"
fi

if [ -n "$RPS_NP3" ] && [ -n "$RPS_P3" ]; then
    DIFF3=$(echo "$RPS_P3 $RPS_NP3" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "Sustained (200 conc)" "$RPS_NP3" "$RPS_P3" "$DIFF3"
fi

echo ""
echo "Done!"
