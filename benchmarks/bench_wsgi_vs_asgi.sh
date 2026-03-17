#!/bin/bash
# Benchmark comparison: WSGI vs WSGI (owngil) vs ASGI
#
# Compares performance between WSGI, WSGI with owngil, and ASGI worker classes
#
# For owngil mode (per-interpreter GIL), set PYTHON_CONFIG to point to
# a Python 3.14+ python-config script:
#   export PYTHON_CONFIG=/path/to/python3.14-config
#   ./benchmarks/bench_wsgi_vs_asgi.sh

set -e

cd "$(dirname "$0")/.."

# Check if ab is available
if ! command -v ab &> /dev/null; then
    echo "Error: 'ab' (Apache Bench) not found."
    exit 1
fi

# Configuration
REQUESTS=10000
CONCURRENCY=100
PORT_WSGI=8765
PORT_WSGI_OWNGIL=8767
PORT_ASGI=8766

# Check for Python 3.12+ for owngil mode and rebuild if PYTHON_CONFIG is set
RUN_OWNGIL=false
if [ -n "$PYTHON_CONFIG" ]; then
    if [ -x "$PYTHON_CONFIG" ]; then
        PY_VERSION=$("$PYTHON_CONFIG" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
        PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
        if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 12 ]; then
            RUN_OWNGIL=true
            echo "Found Python $PY_VERSION for owngil mode"
            echo "Rebuilding with PYTHON_CONFIG=$PYTHON_CONFIG..."
            rm -rf _build/default/lib/erlang_python
            PYTHON_CONFIG="$PYTHON_CONFIG" rebar3 compile
        else
            echo "Warning: PYTHON_CONFIG points to Python $PY_VERSION, owngil requires 3.12+"
            echo "Compiling hornbeam..."
            rebar3 compile
        fi
    else
        echo "Warning: PYTHON_CONFIG=$PYTHON_CONFIG is not executable"
        echo "Compiling hornbeam..."
        rebar3 compile
    fi
else
    # Check if project is compiled
    if [ ! -d "_build/default/lib" ]; then
        echo "Compiling hornbeam..."
        rebar3 compile
    fi
fi

cleanup() {
    echo "Cleaning up..."
    kill $PID_WSGI 2>/dev/null || true
    [ "$RUN_OWNGIL" = true ] && kill $PID_WSGI_OWNGIL 2>/dev/null || true
    kill $PID_ASGI 2>/dev/null || true
    wait $PID_WSGI 2>/dev/null || true
    [ "$RUN_OWNGIL" = true ] && wait $PID_WSGI_OWNGIL 2>/dev/null || true
    wait $PID_ASGI 2>/dev/null || true
}
trap cleanup EXIT

echo "=============================================="
echo "   Hornbeam WSGI vs WSGI (owngil) vs ASGI"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Requests: $REQUESTS"
echo "  Concurrency: $CONCURRENCY"
echo "  owngil mode: $RUN_OWNGIL"
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

# Start WSGI server with owngil (per-interpreter GIL) if Python 3.12+ available
if [ "$RUN_OWNGIL" = true ]; then
    echo "Starting WSGI (owngil) server on port $PORT_WSGI_OWNGIL..."
    PYTHON_CONFIG="$PYTHON_CONFIG" erl -pa _build/default/lib/*/ebin \
        -noshell \
        -eval "
            application:ensure_all_started(hornbeam),
            hornbeam:start(<<\"simple_app:application\">>, #{
                bind => <<\"127.0.0.1:$PORT_WSGI_OWNGIL\">>,
                worker_class => wsgi,
                context_mode => owngil,
                pythonpath => [<<\"benchmarks\">>]
            }).
        " > /dev/null 2>&1 &
    PID_WSGI_OWNGIL=$!
fi

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

# Build list of ports to check
PORTS_TO_CHECK="$PORT_WSGI $PORT_ASGI"
[ "$RUN_OWNGIL" = true ] && PORTS_TO_CHECK="$PORT_WSGI $PORT_WSGI_OWNGIL $PORT_ASGI"

# Verify servers are running
for port in $PORTS_TO_CHECK; do
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
[ "$RUN_OWNGIL" = true ] && ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_WSGI_OWNGIL/ > /dev/null 2>&1 || true
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

if [ "$RUN_OWNGIL" = true ]; then
    echo ""
    echo "--- WSGI (owngil) ---"
    RESULT_O1=$(ab -n $REQUESTS -c $CONCURRENCY -k http://127.0.0.1:$PORT_WSGI_OWNGIL/ 2>&1)
    RPS_O1=$(echo "$RESULT_O1" | grep "Requests per second" | awk '{print $4}')
    LAT_O1=$(echo "$RESULT_O1" | grep "Time per request" | head -1 | awk '{print $4}')
    FAIL_O1=$(echo "$RESULT_O1" | grep "Failed requests" | awk '{print $3}')
    echo "  Requests/sec: $RPS_O1"
    echo "  Latency:      ${LAT_O1}ms"
    echo "  Failed:       $FAIL_O1"
fi

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

if [ "$RUN_OWNGIL" = true ]; then
    echo ""
    echo "--- WSGI (owngil) ---"
    RESULT_O2=$(ab -n 5000 -c 500 -k http://127.0.0.1:$PORT_WSGI_OWNGIL/ 2>&1)
    RPS_O2=$(echo "$RESULT_O2" | grep "Requests per second" | awk '{print $4}')
    LAT_O2=$(echo "$RESULT_O2" | grep "Time per request" | head -1 | awk '{print $4}')
    FAIL_O2=$(echo "$RESULT_O2" | grep "Failed requests" | awk '{print $3}')
    echo "  Requests/sec: $RPS_O2"
    echo "  Latency:      ${LAT_O2}ms"
    echo "  Failed:       $FAIL_O2"
fi

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

if [ "$RUN_OWNGIL" = true ]; then
    echo ""
    echo "--- WSGI (owngil) ---"
    RESULT_O3=$(ab -n 20000 -c 200 -k http://127.0.0.1:$PORT_WSGI_OWNGIL/ 2>&1)
    RPS_O3=$(echo "$RESULT_O3" | grep "Requests per second" | awk '{print $4}')
    LAT_O3=$(echo "$RESULT_O3" | grep "Time per request" | head -1 | awk '{print $4}')
    FAIL_O3=$(echo "$RESULT_O3" | grep "Failed requests" | awk '{print $3}')
    echo "  Requests/sec: $RPS_O3"
    echo "  Latency:      ${LAT_O3}ms"
    echo "  Failed:       $FAIL_O3"
fi

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

if [ "$RUN_OWNGIL" = true ]; then
    echo ""
    echo "--- WSGI (owngil) ---"
    RESULT_O4=$(ab -n 1000 -c 50 -k http://127.0.0.1:$PORT_WSGI_OWNGIL/large 2>&1)
    RPS_O4=$(echo "$RESULT_O4" | grep "Requests per second" | awk '{print $4}')
    LAT_O4=$(echo "$RESULT_O4" | grep "Time per request" | head -1 | awk '{print $4}')
    FAIL_O4=$(echo "$RESULT_O4" | grep "Failed requests" | awk '{print $3}')
    echo "  Requests/sec: $RPS_O4"
    echo "  Latency:      ${LAT_O4}ms"
    echo "  Failed:       $FAIL_O4"
fi

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

if [ "$RUN_OWNGIL" = true ]; then
    printf "%-25s %12s %12s %12s\n" "Test" "WSGI" "WSGI(owngil)" "ASGI"
    printf "%-25s %12s %12s %12s\n" "-------------------------" "------------" "------------" "------------"

    if [ -n "$RPS_W1" ] && [ -n "$RPS_O1" ] && [ -n "$RPS_A1" ]; then
        printf "%-25s %9s/s %9s/s %9s/s\n" "Simple (100 conc)" "$RPS_W1" "$RPS_O1" "$RPS_A1"
    fi
    if [ -n "$RPS_W2" ] && [ -n "$RPS_O2" ] && [ -n "$RPS_A2" ]; then
        printf "%-25s %9s/s %9s/s %9s/s\n" "High conc (500 conc)" "$RPS_W2" "$RPS_O2" "$RPS_A2"
    fi
    if [ -n "$RPS_W3" ] && [ -n "$RPS_O3" ] && [ -n "$RPS_A3" ]; then
        printf "%-25s %9s/s %9s/s %9s/s\n" "Sustained (200 conc)" "$RPS_W3" "$RPS_O3" "$RPS_A3"
    fi
    if [ -n "$RPS_W4" ] && [ -n "$RPS_O4" ] && [ -n "$RPS_A4" ]; then
        printf "%-25s %9s/s %9s/s %9s/s\n" "Large response (50 conc)" "$RPS_W4" "$RPS_O4" "$RPS_A4"
    fi
else
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
fi

echo ""
echo "Done!"
