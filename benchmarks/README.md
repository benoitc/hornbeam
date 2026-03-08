# Hornbeam FD Reactor Benchmarks

## Prerequisites

- wrk (HTTP benchmarking tool)
- Erlang/OTP
- hornbeam compiled

Install wrk:
```bash
# macOS
brew install wrk

# Linux
apt install wrk
```

## Running Benchmarks

### Option 1: Full Application Mode

Start hornbeam in one terminal:
```bash
cd /path/to/hornbeam
rebar3 shell

# In the Erlang shell, start with NIF mode:
hornbeam:start("scenarios.simple_get:app", #{
    bind => "127.0.0.1:18888",
    backend_mode => nif,
    workers => 4
}).
```

Run wrk in another terminal:
```bash
wrk -t2 -c100 -d10s http://127.0.0.1:18888/
```

Stop and restart with FD reactor mode:
```erlang
hornbeam:stop().
hornbeam:start("scenarios.simple_get:app", #{
    bind => "127.0.0.1:18888",
    backend_mode => fd_reactor,
    workers => 4
}).
```

Run wrk again and compare results.

### Option 2: Quick Test

For a quick comparison without wrk:
```erlang
%% In rebar3 shell
hornbeam:start("scenarios.simple_get:app", #{backend_mode => nif}).
%% Make requests with hackney or httpc
{ok, _, _, Ref} = hackney:get("http://127.0.0.1:8000/").
hackney:body(Ref).
hornbeam:stop().
```

## Benchmark Scenarios

| Scenario | Description | What it measures |
|----------|-------------|------------------|
| simple_get | GET /, empty response | Base overhead |
| post_1kb | POST with 1KB body | Small body handling |
| post_64kb | POST with 64KB body | Medium body streaming |
| response_1kb | GET, 1KB response | Small response |
| file_response | GET, serve 1MB file | sendfile() benefit |

## Expected Results

The FD reactor mode should show improvements in:
- Large body handling (streaming vs buffering)
- File responses (potential sendfile support)
- High concurrency (better GIL management)

The NIF mode may be faster for:
- Simple GET requests (lower overhead)
- Small responses (no socketpair overhead)
