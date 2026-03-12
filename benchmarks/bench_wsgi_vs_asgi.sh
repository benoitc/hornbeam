#!/bin/bash
# Benchmark comparison: WSGI vs ASGI
#
# Compares performance between WSGI and ASGI worker classes

set -e

cd "$(dirname "$0")/.."

# Check if ab is available
if ! command -v ab &> /dev/null; then
    echo "Error: 'ab' (Apache Bench) not found."
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
PORT_WSGI=8765
PORT_ASGI=8766

cleanup() {
    echo "Cleaning up..."
    kill $PID_WSGI 2>/dev/null || true
    kill $PID_ASGI 2>/dev/null || true
    wait $PID_WSGI 2>/dev/null || true
    wait $PID_ASGI 2>/dev/null || true
}
trap cleanup EXIT

echo "=============================================="
echo "       Hornbeam WSGI vs ASGI Benchmark"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Requests: $REQUESTS"
echo "  Concurrency: $CONCURRENCY"
echo ""

# Start WSGI server
echo "Starting WSGI server on port $PORT_WSGI..."
erl -pa _build/default/lib/*/ebin \
    -noshell \
    -eval "
        application:ensure_all_started(hornbeam),
        hornbeam:start(<<\"simple_app:application\">>, #{
            bind => <<\"127.0.0.1:$PORT_WSGI\">>,
            worker_class => wsgi,
            pythonpath => [<<\"benchmarks\">>]
        }).
    " > /dev/null 2>&1 &
PID_WSGI=$!

# Start ASGI server
echo "Starting ASGI server on port $PORT_ASGI..."
erl -pa _build/default/lib/*/ebin \
    -noshell \
    -eval "
        application:ensure_all_started(hornbeam),
        hornbeam:start(<<\"simple_asgi_app:application\">>, #{
            bind => <<\"127.0.0.1:$PORT_ASGI\">>,
            worker_class => asgi,
            pythonpath => [<<\"benchmarks\">>]
        }).
    " > /dev/null 2>&1 &
PID_ASGI=$!

# Wait for servers to be ready
echo "Waiting for servers to start..."
sleep 4

# Verify servers are running
for port in $PORT_WSGI $PORT_ASGI; do
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
ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_WSGI/ > /dev/null 2>&1 || true
ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_ASGI/ > /dev/null 2>&1 || true
sleep 1

echo ""
echo "=============================================="
echo "  Test 1: Simple Requests ($REQUESTS req, $CONCURRENCY concurrent)"
echo "=============================================="

echo ""
echo "--- WSGI ---"
RESULT_W1=$(ab -n $REQUESTS -c $CONCURRENCY -k http://127.0.0.1:$PORT_WSGI/ 2>&1)
RPS_W1=$(echo "$RESULT_W1" | grep "Requests per second" | awk '{print $4}')
LAT_W1=$(echo "$RESULT_W1" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_W1=$(echo "$RESULT_W1" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_W1"
echo "  Latency:      ${LAT_W1}ms"
echo "  Failed:       $FAIL_W1"

echo ""
echo "--- ASGI ---"
RESULT_A1=$(ab -n $REQUESTS -c $CONCURRENCY -k http://127.0.0.1:$PORT_ASGI/ 2>&1)
RPS_A1=$(echo "$RESULT_A1" | grep "Requests per second" | awk '{print $4}')
LAT_A1=$(echo "$RESULT_A1" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_A1=$(echo "$RESULT_A1" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_A1"
echo "  Latency:      ${LAT_A1}ms"
echo "  Failed:       $FAIL_A1"

echo ""
echo "=============================================="
echo "  Test 2: High Concurrency (5000 req, 500 concurrent)"
echo "=============================================="

echo ""
echo "--- WSGI ---"
RESULT_W2=$(ab -n 5000 -c 500 -k http://127.0.0.1:$PORT_WSGI/ 2>&1)
RPS_W2=$(echo "$RESULT_W2" | grep "Requests per second" | awk '{print $4}')
LAT_W2=$(echo "$RESULT_W2" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_W2=$(echo "$RESULT_W2" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_W2"
echo "  Latency:      ${LAT_W2}ms"
echo "  Failed:       $FAIL_W2"

echo ""
echo "--- ASGI ---"
RESULT_A2=$(ab -n 5000 -c 500 -k http://127.0.0.1:$PORT_ASGI/ 2>&1)
RPS_A2=$(echo "$RESULT_A2" | grep "Requests per second" | awk '{print $4}')
LAT_A2=$(echo "$RESULT_A2" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_A2=$(echo "$RESULT_A2" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_A2"
echo "  Latency:      ${LAT_A2}ms"
echo "  Failed:       $FAIL_A2"

echo ""
echo "=============================================="
echo "  Test 3: Sustained Load (20000 req, 200 concurrent)"
echo "=============================================="

echo ""
echo "--- WSGI ---"
RESULT_W3=$(ab -n 20000 -c 200 -k http://127.0.0.1:$PORT_WSGI/ 2>&1)
RPS_W3=$(echo "$RESULT_W3" | grep "Requests per second" | awk '{print $4}')
LAT_W3=$(echo "$RESULT_W3" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_W3=$(echo "$RESULT_W3" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_W3"
echo "  Latency:      ${LAT_W3}ms"
echo "  Failed:       $FAIL_W3"

echo ""
echo "--- ASGI ---"
RESULT_A3=$(ab -n 20000 -c 200 -k http://127.0.0.1:$PORT_ASGI/ 2>&1)
RPS_A3=$(echo "$RESULT_A3" | grep "Requests per second" | awk '{print $4}')
LAT_A3=$(echo "$RESULT_A3" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_A3=$(echo "$RESULT_A3" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_A3"
echo "  Latency:      ${LAT_A3}ms"
echo "  Failed:       $FAIL_A3"

echo ""
echo "=============================================="
echo "  Test 4: Large Response (1000 req, 50 concurrent)"
echo "=============================================="

echo ""
echo "--- WSGI ---"
RESULT_W4=$(ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_WSGI/large 2>&1)
RPS_W4=$(echo "$RESULT_W4" | grep "Requests per second" | awk '{print $4}')
LAT_W4=$(echo "$RESULT_W4" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_W4=$(echo "$RESULT_W4" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_W4"
echo "  Latency:      ${LAT_W4}ms"
echo "  Failed:       $FAIL_W4"

echo ""
echo "--- ASGI ---"
RESULT_A4=$(ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_ASGI/large 2>&1)
RPS_A4=$(echo "$RESULT_A4" | grep "Requests per second" | awk '{print $4}')
LAT_A4=$(echo "$RESULT_A4" | grep "Time per request" | head -1 | awk '{print $4}')
FAIL_A4=$(echo "$RESULT_A4" | grep "Failed requests" | awk '{print $3}')
echo "  Requests/sec: $RPS_A4"
echo "  Latency:      ${LAT_A4}ms"
echo "  Failed:       $FAIL_A4"

echo ""
echo "=============================================="
echo "  Summary"
echo "=============================================="
echo ""
printf "%-25s %15s %15s %10s\n" "Test" "WSGI" "ASGI" "Diff"
printf "%-25s %15s %15s %10s\n" "-------------------------" "---------------" "---------------" "----------"

# Calculate differences
if [ -n "$RPS_W1" ] && [ -n "$RPS_A1" ]; then
    DIFF1=$(echo "$RPS_A1 $RPS_W1" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "Simple (100 conc)" "$RPS_W1" "$RPS_A1" "$DIFF1"
fi

if [ -n "$RPS_W2" ] && [ -n "$RPS_A2" ]; then
    DIFF2=$(echo "$RPS_A2 $RPS_W2" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "High conc (500 conc)" "$RPS_W2" "$RPS_A2" "$DIFF2"
fi

if [ -n "$RPS_W3" ] && [ -n "$RPS_A3" ]; then
    DIFF3=$(echo "$RPS_A3 $RPS_W3" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "Sustained (200 conc)" "$RPS_W3" "$RPS_A3" "$DIFF3"
fi

if [ -n "$RPS_W4" ] && [ -n "$RPS_A4" ]; then
    DIFF4=$(echo "$RPS_A4 $RPS_W4" | awk '{if($2>0) printf "%.1f%%", (($1-$2)/$2)*100; else print "N/A"}')
    printf "%-25s %12s/s %12s/s %10s\n" "Large response (50 conc)" "$RPS_W4" "$RPS_A4" "$DIFF4"
fi

echo ""
echo "Done!"
