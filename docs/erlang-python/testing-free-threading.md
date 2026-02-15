---
title: Testing with Free-Threaded Python
description: How to test erlang_python with Python's experimental free-threading mode (no GIL) for maximum parallel execution performance.
order: 9
---

# Testing with Free-Threaded Python

This guide explains how to test erlang_python with Python's experimental free-threading mode (no GIL).

## Overview

Python 3.13+ can be built with `--disable-gil` to create a "free-threaded" build where the Global Interpreter Lock is removed. This allows true parallel execution of Python code across multiple threads.

erlang_python automatically detects free-threaded Python and uses direct execution (no executor thread) for maximum performance.

## Installing Free-Threaded Python

### Option 1: Using pyenv (Recommended)

```bash
# Install pyenv if not already installed
curl https://pyenv.run | bash

# Install free-threaded Python 3.13+
PYTHON_CONFIGURE_OPTS="--disable-gil" pyenv install 3.13.0

# Or for 3.14+
PYTHON_CONFIGURE_OPTS="--disable-gil" pyenv install 3.14.0
```

### Option 2: Build from Source

```bash
# Download Python source
wget https://www.python.org/ftp/python/3.13.0/Python-3.13.0.tar.xz
tar xf Python-3.13.0.tar.xz
cd Python-3.13.0

# Configure with --disable-gil
./configure --prefix=$HOME/python-nogil --disable-gil --enable-optimizations

# Build and install
make -j$(nproc)
make install
```

### Option 3: macOS with Homebrew

```bash
# Check if free-threading option is available
brew info python@3.13

# If available:
brew install python@3.13 --with-freethreading
```

### Option 4: Using Docker

```dockerfile
FROM python:3.13-rc

# Python RC images may include free-threading
# Check with: python -c "import sys; print(hasattr(sys, '_is_gil_enabled'))"
```

## Verifying Free-Threading is Enabled

```bash
# Check if GIL is disabled
python3 -c "
import sys
if hasattr(sys, '_is_gil_enabled'):
    print('Free-threading supported:', not sys._is_gil_enabled())
else:
    print('Free-threading not available (Python < 3.13 or GIL enabled)')
"
```

Expected output for free-threaded Python:
```
Free-threading supported: True
```

## Building erlang_python for Free-Threading

```bash
# Clean previous builds
rebar3 clean

# Set Python config path (adjust for your installation)
export PYTHON_CONFIG=$HOME/python-nogil/bin/python3-config

# Or if using pyenv
export PYTHON_CONFIG=$(pyenv prefix 3.13.0)/bin/python3-config

# Build
rebar3 compile
```

## Verifying Free-Threading Mode

```erlang
1> application:ensure_all_started(erlang_python).
{ok, [erlang_python]}

2> py:execution_mode().
free_threaded  % Should show 'free_threaded' instead of 'subinterp' or 'multi_executor'

3> py:num_executors().
1  % In free_threaded mode, no executor pool is used
```

## Running Tests

```bash
# Run the test suite
rebar3 ct --suite=py_SUITE

# Run benchmarks
escript examples/benchmark.erl --full
```

## Performance Comparison

Run benchmarks with both standard and free-threaded Python to compare:

### Standard Python (with GIL)
```bash
# Use standard Python
export PYTHON_CONFIG=/usr/bin/python3-config
rebar3 clean && rebar3 compile
escript examples/benchmark.erl --concurrent
```

### Free-Threaded Python
```bash
# Use free-threaded Python
export PYTHON_CONFIG=$HOME/python-nogil/bin/python3-config
rebar3 clean && rebar3 compile
escript examples/benchmark.erl --concurrent
```

Expected results:
- Free-threaded mode should show higher throughput for concurrent CPU-bound workloads
- The difference is most noticeable with many concurrent processes making Python calls

## Caveats

### Extension Compatibility

Not all Python C extensions are compatible with free-threading. Extensions that rely on the GIL for thread safety may crash or produce incorrect results.

**Known compatible:**
- Standard library modules
- NumPy (recent versions)

**May have issues:**
- Older C extensions
- Extensions using non-thread-safe C libraries

### Memory Model

Free-threaded Python uses a different memory model. Be aware of:
- Increased memory usage (per-object locks)
- Different garbage collection behavior
- Potential for data races in Python code

### Testing Recommendations

1. **Start with unit tests**: Ensure basic functionality works
2. **Test concurrency**: Run concurrent benchmarks
3. **Check for crashes**: Monitor for segfaults during heavy load
4. **Profile memory**: Watch for memory leaks or bloat

## Troubleshooting

### Build Fails

```
error: Python.h not found
```

Ensure `PYTHON_CONFIG` points to the free-threaded Python installation:
```bash
ls $(dirname $(which python3))/../include/*/Python.h
```

### Mode Shows 'multi_executor' Instead of 'free_threaded'

The Python build may not have `Py_GIL_DISABLED` defined. Verify:
```bash
python3 -c "import sysconfig; print(sysconfig.get_config_var('Py_GIL_DISABLED'))"
```

Should print `1` for free-threaded builds.

### Crashes Under Load

Some extensions may not be thread-safe. Try:
1. Isolate the problematic extension
2. Check if a thread-safe version exists
3. Fall back to sub-interpreter mode for those calls

## See Also

- [PEP 703 - Making the GIL Optional](https://peps.python.org/pep-0703/)
- [Python Free-Threading Documentation](https://docs.python.org/3.13/howto/free-threading-python.html)
- [Scalability Guide](scalability.md)
