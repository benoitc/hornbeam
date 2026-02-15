---
title: Getting Started with Erlang Python
description: A walkthrough guide for using erlang_python to execute Python code from Erlang, covering installation, basic usage, and core features.
order: 1
---

# erlang_python

[![Hex.pm](https://img.shields.io/hexpm/v/erlang_python.svg)](https://hex.pm/packages/erlang_python)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/erlang_python)
[![License](https://img.shields.io/hexpm/l/erlang_python.svg)](https://github.com/benoitc/erlang-python/blob/main/LICENSE)

**Combine Python's ML/AI ecosystem with Erlang's concurrency.**

Run Python code from Erlang or Elixir with true parallelism, async/await support,
and seamless integration. Build AI-powered applications that scale.

## Overview

erlang_python embeds Python into the BEAM VM, letting you call Python functions,
evaluate expressions, and stream from generators - all without blocking Erlang
schedulers.

**Three paths to parallelism:**
- **Sub-interpreters** (Python 3.12+) - Each interpreter has its own GIL
- **Free-threaded Python** (3.13+) - No GIL at all
- **BEAM processes** - Fan out work across lightweight Erlang processes

Key features:
- **Async/await** - Call Python async functions, gather results, stream from async generators
- **Dirty NIF execution** - Python runs on dirty schedulers, never blocking the BEAM
- **Elixir support** - Works seamlessly from Elixir via the `:py` module
- **Bidirectional calls** - Python can call back into registered Erlang/Elixir functions
- **Type conversion** - Automatic conversion between Erlang and Python types
- **Streaming** - Iterate over Python generators chunk-by-chunk
- **Virtual environments** - Activate venvs for dependency isolation
- **AI/ML ready** - Examples for embeddings, semantic search, RAG, and LLMs

## Requirements

- Erlang/OTP 27+
- Python 3.12+ (3.13+ for free-threading)
- C compiler (gcc, clang)

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {erlang_python, "1.2.0"}
]}.
```

Then compile:

```bash
rebar3 compile
```

## Quick Start

### Erlang

```erlang
%% Start the application
application:ensure_all_started(erlang_python).

%% Call a Python function
{ok, 4.0} = py:call(math, sqrt, [16]).

%% With keyword arguments
{ok, Json} = py:call(json, dumps, [#{foo => bar}], #{indent => 2}).

%% Evaluate an expression
{ok, 45} = py:eval(<<"sum(range(10))">>).

%% Evaluate with local variables
{ok, 25} = py:eval(<<"x * y">>, #{x => 5, y => 5}).

%% Async calls
Ref = py:call_async(math, factorial, [100]),
{ok, Result} = py:await(Ref).

%% Streaming from generators
{ok, [0,1,4,9,16]} = py:stream_eval(<<"(x**2 for x in range(5))">>).
```

### Elixir

```elixir
# Start the application
{:ok, _} = Application.ensure_all_started(:erlang_python)

# Call Python functions
{:ok, 4.0} = :py.call(:math, :sqrt, [16])

# Evaluate expressions
{:ok, result} = :py.eval("2 + 2")

# With variables
{:ok, 100} = :py.eval("x * y", %{x: 10, y: 10})

# Call with keyword arguments
{:ok, json} = :py.call(:json, :dumps, [%{name: "Elixir"}], %{indent: 2})
```

## Erlang/Elixir Functions Callable from Python

Register Erlang or Elixir functions that Python code can call back into:

### Erlang

```erlang
%% Register a function
py:register_function(my_func, fun([X, Y]) -> X + Y end).

%% Call from Python - native import syntax (recommended)
{ok, Result} = py:exec(<<"
from erlang import my_func
result = my_func(10, 20)
">>).
%% Result = 30

%% Or use attribute-style access
{ok, 30} = py:eval(<<"erlang.my_func(10, 20)">>).

%% Legacy syntax still works
{ok, 30} = py:eval(<<"erlang.call('my_func', 10, 20)">>).

%% Unregister when done
py:unregister_function(my_func).
```

### Elixir

```elixir
# Register an Elixir function
:py.register_function(:factorial, fn [n] ->
  Enum.reduce(1..n, 1, &*/2)
end)

# Call from Python - native import syntax
{:ok, 3628800} = :py.exec("""
from erlang import factorial
result = factorial(10)
""")

# Or use attribute-style access
{:ok, 3628800} = :py.eval("erlang.factorial(10)")
```

### Python Calling Syntax

From Python code, registered Erlang functions can be called in three ways:

```python
# 1. Import syntax (most Pythonic)
from erlang import my_func
result = my_func(10, 20)

# 2. Attribute syntax
import erlang
result = erlang.my_func(10, 20)

# 3. Explicit call (legacy)
import erlang
result = erlang.call('my_func', 10, 20)
```

All three methods are equivalent. The import and attribute syntaxes provide
a more natural Python experience.

### Reentrant Callbacks

Python→Erlang→Python callbacks are fully supported. When Python code calls
an Erlang function that in turn calls back into Python, the system handles
this transparently without deadlocking:

```erlang
%% Register an Erlang function that calls Python
py:register_function(double_via_python, fun([X]) ->
    {ok, Result} = py:call('__main__', double, [X]),
    Result
end).

%% Define Python functions
py:exec(<<"
def double(x):
    return x * 2

def process(x):
    from erlang import call
    # This calls Erlang, which calls Python's double()
    doubled = call('double_via_python', x)
    return doubled + 1
">>).

%% Test the full round-trip
{ok, 21} = py:call('__main__', process, [10]).
%% 10 → double_via_python → double(10)=20 → +1 = 21
```

The implementation uses a suspension/resume mechanism that frees the dirty
scheduler while the Erlang callback executes, preventing deadlocks even with
multiple levels of nesting.

## Shared State Between Workers

Python workers don't share namespace state, but you can share data via the
built-in state API:

### From Python

```python
from erlang import state_set, state_get, state_delete, state_keys
from erlang import state_incr, state_decr

# Store data (survives across calls, shared between workers)
state_set('my_key', {'data': [1, 2, 3], 'count': 42})

# Retrieve data
value = state_get('my_key')  # {'data': [1, 2, 3], 'count': 42}

# Atomic counters (thread-safe, great for metrics)
state_incr('requests')       # returns 1
state_incr('requests', 10)   # returns 11
state_decr('requests')       # returns 10

# List keys
keys = state_keys()  # ['my_key', 'requests', ...]

# Delete
state_delete('my_key')
```

### From Erlang/Elixir

```erlang
%% Store and fetch
py:state_store(<<"my_key">>, #{value => 42}).
{ok, #{value := 42}} = py:state_fetch(<<"my_key">>).

%% Atomic counters
1 = py:state_incr(<<"hits">>).
11 = py:state_incr(<<"hits">>, 10).
10 = py:state_decr(<<"hits">>).

%% List keys and clear
Keys = py:state_keys().
py:state_clear().
```

This is backed by ETS with `{write_concurrency, true}`, so counters are atomic and fast.

## Async/Await Support

Call Python async functions without blocking:

```erlang
%% Call an async function
Ref = py:async_call(aiohttp, get, [<<"https://api.example.com/data">>]),
{ok, Response} = py:async_await(Ref).

%% Gather multiple async calls concurrently
{ok, Results} = py:async_gather([
    {aiohttp, get, [<<"https://api.example.com/users">>]},
    {aiohttp, get, [<<"https://api.example.com/posts">>]},
    {aiohttp, get, [<<"https://api.example.com/comments">>]}
]).

%% Stream from async generators
{ok, Chunks} = py:async_stream(mymodule, async_generator, [args]).
```

## Parallel Execution with Sub-interpreters

True parallelism without GIL contention using Python 3.12+ sub-interpreters:

```erlang
%% Execute multiple calls in parallel across sub-interpreters
{ok, Results} = py:parallel([
    {math, factorial, [100]},
    {math, factorial, [200]},
    {math, factorial, [300]},
    {math, factorial, [400]}
]).
%% Each call runs in its own interpreter with its own GIL
```

## Parallel Processing with BEAM Processes

Leverage Erlang's lightweight processes for massive parallelism:

```erlang
%% Register parallel map function
py:register_function(parallel_map, fun([FuncName, Items]) ->
    Parent = self(),
    Refs = [begin
        Ref = make_ref(),
        spawn(fun() ->
            Result = execute(FuncName, Item),
            Parent ! {Ref, Result}
        end),
        Ref
    end || Item <- Items],
    [receive {Ref, R} -> R after 5000 -> timeout end || Ref <- Refs]
end).

%% Call from Python - processes 10 items in parallel
{ok, Results} = py:eval(
    <<"__import__('erlang').call('parallel_map', 'compute', items)">>,
    #{items => lists:seq(1, 10)}
).
```

**Benchmark Results** (from `examples/erlang_concurrency.erl`):
```
Sequential: 10 Python calls × 100ms each = 1.01 seconds
Parallel:   10 BEAM processes calling Python = 0.10 seconds
```

The speedup is linear with the number of items when work is I/O-bound or
distributed across sub-interpreters.

## Virtual Environment Support

```erlang
%% Activate a venv
ok = py:activate_venv(<<"/path/to/venv">>).

%% Use packages from venv
{ok, Model} = py:call(sentence_transformers, 'SentenceTransformer', [<<"all-MiniLM-L6-v2">>]).

%% Deactivate when done
ok = py:deactivate_venv().
```

## Examples

The `examples/` directory contains runnable demonstrations:

### Semantic Search
```bash
# Setup
python3 -m venv /tmp/ai-venv
/tmp/ai-venv/bin/pip install sentence-transformers numpy

# Run
escript examples/semantic_search.erl
```

### RAG (Retrieval-Augmented Generation)
```bash
# Setup (also install Ollama and pull a model)
/tmp/ai-venv/bin/pip install sentence-transformers numpy requests
ollama pull llama3.2

# Run
escript examples/rag_example.erl
```

### AI Chat
```bash
escript examples/ai_chat.erl
```

### Erlang Concurrency from Python
```bash
# Demonstrates 10x speedup with BEAM processes
escript examples/erlang_concurrency.erl
```

### Elixir Integration
```bash
elixir --erl "-pa _build/default/lib/erlang_python/ebin" examples/elixir_example.exs
```

## API Reference

### Function Calls

```erlang
{ok, Result} = py:call(Module, Function, Args).
{ok, Result} = py:call(Module, Function, Args, KwArgs).
{ok, Result} = py:call(Module, Function, Args, KwArgs, Timeout).

%% Async
Ref = py:call_async(Module, Function, Args).
{ok, Result} = py:await(Ref).
{ok, Result} = py:await(Ref, Timeout).
```

### Expression Evaluation

```erlang
{ok, 42} = py:eval(<<"21 * 2">>).
{ok, 100} = py:eval(<<"x * y">>, #{x => 10, y => 10}).
{ok, Result} = py:eval(Expression, Locals, Timeout).
```

### Streaming

```erlang
{ok, Chunks} = py:stream(Module, GeneratorFunc, Args).
{ok, [0,1,4,9,16]} = py:stream_eval(<<"(x**2 for x in range(5))">>).
```

### Callbacks

```erlang
py:register_function(Name, fun([Args]) -> Result end).
py:register_function(Name, Module, Function).
py:unregister_function(Name).
```

### Memory and GC

```erlang
{ok, Stats} = py:memory_stats().
{ok, Collected} = py:gc().
ok = py:tracemalloc_start().
ok = py:tracemalloc_stop().
```

## Type Mappings

### Erlang to Python

| Erlang | Python |
|--------|--------|
| `integer()` | `int` |
| `float()` | `float` |
| `binary()` | `str` |
| `atom()` | `str` |
| `true` / `false` | `True` / `False` |
| `none` / `nil` | `None` |
| `list()` | `list` |
| `tuple()` | `tuple` |
| `map()` | `dict` |

### Python to Erlang

| Python | Erlang |
|--------|--------|
| `int` | `integer()` |
| `float` | `float()` |
| `str` | `binary()` |
| `bytes` | `binary()` |
| `True` / `False` | `true` / `false` |
| `None` | `none` |
| `list` | `list()` |
| `tuple` | `tuple()` |
| `dict` | `map()` |

## Configuration

```erlang
%% sys.config
[
  {erlang_python, [
    {num_workers, 4},           %% Python worker pool size
    {max_concurrent, 17},       %% Max concurrent operations (default: schedulers * 2 + 1)
    {num_executors, 4}          %% Executor threads (multi-executor mode)
  ]}
].
```

## Execution Modes

The library auto-detects the best execution mode:

| Mode | Python Version | Parallelism |
|------|----------------|-------------|
| Free-threaded | 3.13+ (nogil) | True parallel, no GIL |
| Sub-interpreter | 3.12+ | Per-interpreter GIL |
| Multi-executor | Any | GIL contention |

Check current mode:
```erlang
py:execution_mode().  %% => free_threaded | subinterp | multi_executor
```

## Error Handling

```erlang
{error, {'NameError', "name 'x' is not defined"}} = py:eval(<<"x">>).
{error, {'ZeroDivisionError', "division by zero"}} = py:eval(<<"1/0">>).
{error, timeout} = py:eval(<<"sum(range(10**9))">>, #{}, 100).
```

## Next Steps

- [Type Conversion](type-conversion) - Detailed type mapping
- [Context Affinity](context-affinity) - Preserving Python state
- [Streaming](streaming) - Working with generators
- [Memory Management](memory) - GC and debugging
- [Scalability](scalability) - Parallelism and performance
- [AI Integration](ai-integration) - ML/AI examples

## License

Apache-2.0
