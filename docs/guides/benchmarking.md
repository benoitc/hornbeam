---
title: Benchmarking
description: How to benchmark hornbeam and compare performance with other WSGI/ASGI servers.
order: 6
---

# Benchmarking

Hornbeam includes a benchmark suite for measuring performance and comparing against other servers like gunicorn.

## Prerequisites

Install a benchmarking tool:

```bash
# macOS
brew install wrk

# Linux (Ubuntu/Debian)
apt-get install wrk
# or
apt-get install apache2-utils  # for ab
```

## Quick Benchmark

Run the quick benchmark script:

```bash
./benchmarks/quick_bench.sh
```

This runs three test scenarios against the WSGI worker:

1. **Simple requests**: 10,000 requests, 100 concurrent connections
2. **High concurrency**: 5,000 requests, 500 concurrent connections
3. **Large response**: 1,000 requests with 64KB response bodies

Example output (Apple M4 Pro, Python 3.14, OTP 28):

```
=== Benchmark: Simple requests (10000 requests, 100 concurrent) ===
Requests per second:    33753.57 [#/sec] (mean)
Time per request:       2.963 [ms] (mean)
Failed requests:        0

=== Benchmark: High concurrency (5000 requests, 500 concurrent) ===
Requests per second:    30312.22 [#/sec] (mean)
Time per request:       16.495 [ms] (mean)
Failed requests:        0

=== Benchmark: Large response (1000 requests, 50 concurrent) ===
Requests per second:    27355.29 [#/sec] (mean)
Time per request:       1.828 [ms] (mean)
Failed requests:        0
```

## Results Summary

| Test | Requests/sec | Latency (mean) | Failed |
|------|--------------|----------------|--------|
| Simple (100 concurrent) | **34,731** | 2.88ms | 0 |
| High concurrency (500 concurrent) | **30,114** | 16.6ms | 0 |
| Large response (64KB) | **27,697** | 1.81ms | 0 |

These numbers demonstrate that hornbeam maintains consistent high throughput even under heavy concurrency, thanks to Erlang's lightweight process model.

## Comparison with Gunicorn

Direct comparison using identical WSGI app (4 workers, gunicorn with gthread and 4 threads):

| Test | Hornbeam | Gunicorn sync | Gunicorn gthread | Speedup |
|------|----------|---------------|------------------|---------|
| Simple (100 concurrent) | **34,731** req/s | 3,607 req/s | 3,636 req/s | **9.5x** |
| High concurrency (500 concurrent) | **30,114** req/s | 3,589 req/s | 3,677 req/s | **8.2x** |
| Large response (64KB) | **27,697** req/s | 3,526 req/s | 3,613 req/s | **7.7x** |

### Why the Difference?

**Gunicorn limitations:**
- **GIL contention**: Python's Global Interpreter Lock limits true parallelism
- **Process model**: Each worker is a separate OS process with overhead
- **Connection handling**: Blocking I/O model limits concurrent connections

**Hornbeam advantages:**
- **BEAM scheduler**: Millions of lightweight processes, no OS thread overhead
- **No GIL impact**: Python runs on dirty schedulers, isolated from BEAM
- **Cowboy**: Battle-tested HTTP server handling connections efficiently
- **Zero-copy ETS**: Shared state without serialization overhead

## Python Benchmark Script

For more control, use the Python benchmark script:

```bash
# WSGI benchmarks
python benchmarks/run_benchmark.py

# ASGI benchmarks
python benchmarks/run_benchmark.py --asgi

# Custom bind address
python benchmarks/run_benchmark.py --bind 0.0.0.0:9000

# Save results to JSON
python benchmarks/run_benchmark.py --output results.json
```

## Comparing with Gunicorn

Compare hornbeam performance against gunicorn:

```bash
python benchmarks/compare_servers.py
```

This runs identical benchmarks against both servers and prints a comparison:

```
======================================================================
COMPARISON: GUNICORN vs HORNBEAM
======================================================================
Test                 Gunicorn (req/s)     Hornbeam (req/s)     Diff
----------------------------------------------------------------------
simple               1842.3               12543.2              +580.7%
high_concurrency     1523.1               11892.3              +680.9%
large_response       1234.5               8234.6               +567.2%
```

## Benchmark Apps

The benchmark suite uses minimal apps to measure raw server performance:

### WSGI App (`benchmarks/simple_app.py`)

```python
def application(environ, start_response):
    path = environ.get('PATH_INFO', '/')

    if path == '/large':
        body = b'X' * 65536  # 64KB
    else:
        body = b'Hello, World!'

    status = '200 OK'
    headers = [
        ('Content-Type', 'text/plain'),
        ('Content-Length', str(len(body))),
    ]
    start_response(status, headers)
    return [body]
```

### ASGI App (`benchmarks/simple_asgi_app.py`)

```python
async def application(scope, receive, send):
    if scope['type'] != 'http':
        return

    path = scope.get('path', '/')

    if path == '/large':
        body = b'X' * 65536  # 64KB
    else:
        body = b'Hello, World!'

    await send({
        'type': 'http.response.start',
        'status': 200,
        'headers': [
            [b'content-type', b'text/plain'],
            [b'content-length', str(len(body)).encode()],
        ],
    })
    await send({
        'type': 'http.response.body',
        'body': body,
    })
```

## Running Manual Benchmarks

### Using wrk

```bash
# Start hornbeam
rebar3 shell

# In Erlang shell:
hornbeam:start("myapp:application", #{
    bind => <<"127.0.0.1:8000">>,
    worker_class => wsgi
}).

# In another terminal, run wrk:
wrk -t4 -c100 -d30s --latency http://127.0.0.1:8000/
```

### Using Apache Bench (ab)

```bash
# Simple benchmark
ab -n 10000 -c 100 -k http://127.0.0.1:8000/

# High concurrency
ab -n 5000 -c 500 -k http://127.0.0.1:8000/
```

### Key wrk Flags

| Flag | Description |
|------|-------------|
| `-t` | Number of threads |
| `-c` | Number of connections |
| `-d` | Duration (e.g., `30s`, `1m`) |
| `--latency` | Print latency statistics |

### Key ab Flags

| Flag | Description |
|------|-------------|
| `-n` | Number of requests |
| `-c` | Concurrency level |
| `-k` | Enable HTTP keepalive |

## Performance Tuning

### Workers Configuration

Adjust the number of workers based on your CPU cores:

```erlang
hornbeam:start("app:application", #{
    workers => 8,  % Number of Python workers
    worker_class => wsgi
}).
```

### Connection Limits

For high-concurrency scenarios:

```erlang
hornbeam:start("app:application", #{
    max_requests => 10000,  % Requests per worker before restart
    timeout => 60000        % Request timeout in ms
}).
```

### HTTP/2 for Lower Latency

Enable HTTP/2 for multiplexed connections:

```erlang
hornbeam:start("app:application", #{
    http_version => ['HTTP/2', 'HTTP/1.1'],
    ssl => true,
    certfile => "server.crt",
    keyfile => "server.key"
}).
```

## Understanding Results

### Key Metrics

| Metric | Description |
|--------|-------------|
| Requests/sec | Throughput - higher is better |
| Latency (avg) | Mean response time - lower is better |
| Latency (p99) | 99th percentile latency - measures tail latency |
| Failed requests | Should be 0 for valid benchmarks |

### Why Hornbeam is Fast

1. **BEAM Concurrency**: Erlang handles millions of lightweight processes
2. **No GIL Bottleneck**: Python runs on dirty schedulers, not blocking the BEAM
3. **Efficient I/O**: Cowboy is battle-tested for high-performance HTTP
4. **Connection Multiplexing**: HTTP/2 support reduces connection overhead
5. **Zero-Copy**: ETS shared state avoids serialization overhead

## Realistic Benchmarks

The simple "Hello World" benchmarks measure raw server overhead. For realistic numbers, benchmark your actual application:

```bash
# Start your app
hornbeam:start("myapp:app", #{...}).

# Benchmark specific endpoints
wrk -t4 -c100 -d30s http://localhost:8000/api/users
wrk -t4 -c100 -d30s http://localhost:8000/api/search?q=test
```

Consider:
- Database queries
- External API calls
- ML inference
- File uploads/downloads
- WebSocket connections

## CI Benchmarking

Add benchmarks to your CI pipeline:

```yaml
# .github/workflows/benchmark.yml
name: Benchmark

on:
  pull_request:
    branches: [main]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Erlang
        uses: erlef/setup-beam@v1
        with:
          otp-version: '27.1'

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.13'

      - name: Install wrk
        run: sudo apt-get install -y wrk

      - name: Compile
        run: rebar3 compile

      - name: Run benchmarks
        run: python benchmarks/run_benchmark.py --output results.json

      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-results
          path: results.json
```
