---
title: Logging and Tracing
description: Integrate Python logging with Erlang logger and use distributed tracing with span-based instrumentation for Python code.
order: 8
---

# Python Logging and Tracing Integration

This guide covers integrating Python's `logging` module with Erlang's `logger`, and distributed tracing support for Python code.

## Overview

erlang_python provides:
- **Logging**: Python `logging` forwarded to Erlang `logger`
- **Tracing**: Span-based distributed tracing from Python

Both features use fire-and-forget NIFs, meaning Python execution is never blocked waiting for Erlang.

## Logging

### Quick Start

```erlang
%% Configure Python logging
ok = py:configure_logging().

%% Run Python code that logs
{ok, _} = py:eval(<<"
import logging
logging.info('Hello from Python!')
logging.warning('Something happened')
">>).
```

Log messages appear in your Erlang logger output with domain `[python]`.

### Python API

After `py:configure_logging()`, these functions are available on the `erlang` module:

```python
import erlang

# ErlangHandler - logging.Handler subclass
handler = erlang.ErlangHandler()
logging.getLogger().addHandler(handler)

# Or use the setup helper
erlang.setup_logging(level=20)  # INFO level
erlang.setup_logging(level=10, format='%(name)s: %(message)s')
```

### Erlang API

```erlang
%% Configure with defaults (debug level)
ok = py:configure_logging().

%% Configure with options
ok = py:configure_logging(#{
    level => info,  % debug | info | warning | error | critical
    format => <<"%(name)s - %(message)s">>  % Optional Python format string
}).
```

### Log Level Mapping

| Python Level | Python levelno | Erlang Level |
|--------------|---------------|--------------|
| DEBUG        | 10            | debug        |
| INFO         | 20            | info         |
| WARNING      | 30            | warning      |
| ERROR        | 40            | error        |
| CRITICAL     | 50            | critical     |

### Metadata

Each log message includes Python metadata:

```erlang
%% In your Erlang logger handler, you'll receive:
#{
    domain => [python],
    py_logger => <<"root">>,  % Logger name
    py_meta => #{
        <<"module">> => <<"mymodule">>,
        <<"lineno">> => 42,
        <<"funcName">> => <<"my_function">>
    }
}
```

## Distributed Tracing

### Quick Start

```erlang
%% Enable tracing
ok = py:enable_tracing().

%% Run Python code with spans
{ok, _} = py:eval(<<"
import erlang

with erlang.Span('process-request', user_id=123):
    do_work()
">>).

%% Retrieve collected spans
{ok, Spans} = py:get_traces().
%% Spans = [#{name => <<"process-request">>, status => ok, ...}]

%% Clean up
ok = py:clear_traces().
ok = py:disable_tracing().
```

### Python API

#### Context Manager

```python
import erlang

with erlang.Span('operation-name', key='value', count=42) as span:
    # Your code here
    span.event('checkpoint', items_processed=10)

    # Nested spans
    with erlang.Span('sub-operation'):
        pass
```

#### Decorator

```python
import erlang

@erlang.trace()
def my_function():
    return 42

@erlang.trace(name='custom-name')
def another_function():
    pass
```

### Erlang API

```erlang
%% Enable/disable tracing
ok = py:enable_tracing().
ok = py:disable_tracing().

%% Get all collected spans
{ok, Spans} = py:get_traces().

%% Clear collected spans
ok = py:clear_traces().
```

### Span Structure

Each completed span is a map with these keys:

```erlang
#{
    name => <<"operation-name">>,
    span_id => 12345678901234567890,  % Unique 64-bit ID
    parent_id => 9876543210987654321, % Parent span ID (or 'undefined')
    start_time => 1234567890123,      % Microseconds (monotonic)
    end_time => 1234567890456,
    duration_us => 333,               % Duration in microseconds
    status => ok | error,
    attributes => #{<<"key">> => <<"value">>},
    end_attrs => #{},                 % Attributes added at span end
    events => [                       % Events within the span
        #{
            name => <<"checkpoint">>,
            attrs => #{<<"items_processed">> => 10},
            time => 1234567890200
        }
    ]
}
```

### Error Handling

Spans automatically capture exceptions:

```python
import erlang

try:
    with erlang.Span('risky-operation'):
        raise ValueError('something went wrong')
except ValueError:
    pass

# The span will have:
# - status: 'error'
# - end_attrs: {'exception': 'something went wrong'}
```

### Thread Safety

Both logging and tracing are thread-safe:
- Span context is stored in thread-local storage
- Each thread maintains its own span stack for proper parent-child relationships
- NIFs use atomic operations for receiver registration

## Architecture

```
Python                           NIF                          Erlang
───────                         ─────                        ────────
logging.info(msg)                 │                             │
       │                          │                             │
       ▼                          │                             │
ErlangHandler.emit()              │                             │
       │                          │                             │
       ▼                          │                             │
erlang._log(...)  ───────►  nif_py_log()  ──► enif_send() ──►  py_logger
       │                          │                          (gen_server)
       │ (returns immediately)    │                             │
       ▼                          │                     logger:log(...)
   continue execution             │                             │
```

Key design decisions:
- **Fire-and-forget**: `enif_send()` is non-blocking
- **Level filtering**: Done in NIF before message creation
- **No Python blocking**: Python never waits for Erlang

## Performance Considerations

- Log messages below the configured level are filtered at the NIF level
- No heap allocation occurs for filtered messages
- Tracing disabled by default; enable only when needed
- Span data is accumulated in memory until retrieved with `get_traces()`

## Configuration Options

### Logger

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `level` | atom | `debug` | Minimum log level |
| `format` | binary | `%(message)s` | Python format string |

### Tracer

The tracer has no configuration options. Enable/disable with `py:enable_tracing()`/`py:disable_tracing()`.

## Examples

See `examples/logging_example.erl` for a complete working example.

```erlang
%% Basic usage
{ok, _} = application:ensure_all_started(erlang_python).

%% Logging
ok = py:configure_logging(#{level => info}).
{ok, _} = py:eval(<<"import logging; logging.info('hello')">>).

%% Tracing
ok = py:enable_tracing().
{ok, _} = py:eval(<<"
import erlang
with erlang.Span('work'):
    pass
">>).
{ok, Spans} = py:get_traces().
io:format("Collected ~p spans~n", [length(Spans)]).
```
