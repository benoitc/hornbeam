---
title: Type Conversion
description: Detailed guide on how values are automatically converted between Erlang and Python types, including special cases and performance considerations.
order: 3
---

# Type Conversion

This guide details how values are converted between Erlang and Python.

## Erlang to Python

When calling Python functions or evaluating expressions, Erlang values are automatically converted:

| Erlang | Python | Notes |
|--------|--------|-------|
| `integer()` | `int` | Arbitrary precision supported |
| `float()` | `float` | IEEE 754 double precision |
| `binary()` | `str` | UTF-8 encoded |
| `atom()` | `str` | Converted to string (except special atoms) |
| `true` | `True` | Boolean |
| `false` | `False` | Boolean |
| `none` | `None` | Null value |
| `nil` | `None` | Null value (Elixir compatibility) |
| `undefined` | `None` | Null value |
| `list()` | `list` | Recursively converted |
| `tuple()` | `tuple` | Recursively converted |
| `map()` | `dict` | Keys and values recursively converted |

### Examples

```erlang
%% Integers
py:call(mymod, func, [42]).           %% Python receives: 42
py:call(mymod, func, [123456789012345678901234567890]).  %% Big integers work

%% Floats
py:call(mymod, func, [3.14159]).      %% Python receives: 3.14159

%% Strings (binaries)
py:call(mymod, func, [<<"hello">>]).  %% Python receives: "hello"

%% Atoms become strings
py:call(mymod, func, [foo]).          %% Python receives: "foo"

%% Booleans
py:call(mymod, func, [true, false]).  %% Python receives: True, False

%% None equivalents
py:call(mymod, func, [none]).         %% Python receives: None
py:call(mymod, func, [nil]).          %% Python receives: None
py:call(mymod, func, [undefined]).    %% Python receives: None

%% Lists
py:call(mymod, func, [[1, 2, 3]]).    %% Python receives: [1, 2, 3]

%% Tuples
py:call(mymod, func, [{1, 2, 3}]).    %% Python receives: (1, 2, 3)

%% Maps become dicts
py:call(mymod, func, [#{a => 1, b => 2}]).  %% Python receives: {"a": 1, "b": 2}
```

## Python to Erlang

Return values from Python are converted back to Erlang:

| Python | Erlang | Notes |
|--------|--------|-------|
| `int` | `integer()` | Arbitrary precision supported |
| `float` | `float()` | IEEE 754 double precision |
| `float('nan')` | `nan` | Atom for Not-a-Number |
| `float('inf')` | `infinity` | Atom for positive infinity |
| `float('-inf')` | `neg_infinity` | Atom for negative infinity |
| `str` | `binary()` | UTF-8 encoded |
| `bytes` | `binary()` | Raw bytes |
| `True` | `true` | Boolean |
| `False` | `false` | Boolean |
| `None` | `none` | Null value |
| `list` | `list()` | Recursively converted |
| `tuple` | `tuple()` | Recursively converted |
| `dict` | `map()` | Keys and values recursively converted |
| generator | internal | Used with streaming functions |

### Examples

```erlang
%% Integers
{ok, 42} = py:eval(<<"42">>).
{ok, 123456789012345678901234567890} = py:eval(<<"123456789012345678901234567890">>).

%% Floats
{ok, 3.14} = py:eval(<<"3.14">>).

%% Special floats
{ok, nan} = py:eval(<<"float('nan')">>).
{ok, infinity} = py:eval(<<"float('inf')">>).
{ok, neg_infinity} = py:eval(<<"float('-inf')">>).

%% Strings
{ok, <<"hello">>} = py:eval(<<"'hello'">>).

%% Bytes
{ok, <<72,101,108,108,111>>} = py:eval(<<"b'Hello'">>).

%% Booleans
{ok, true} = py:eval(<<"True">>).
{ok, false} = py:eval(<<"False">>).

%% None
{ok, none} = py:eval(<<"None">>).

%% Lists
{ok, [1, 2, 3]} = py:eval(<<"[1, 2, 3]">>).

%% Tuples
{ok, {1, 2, 3}} = py:eval(<<"(1, 2, 3)">>).

%% Dicts become maps
{ok, #{<<"a">> := 1, <<"b">> := 2}} = py:eval(<<"{'a': 1, 'b': 2}">>).
```

## Special Cases

### NumPy Arrays

NumPy arrays are converted to nested Erlang lists:

```erlang
%% 1D array
{ok, [1.0, 2.0, 3.0]} = py:eval(<<"import numpy as np; np.array([1, 2, 3]).tolist()">>).

%% 2D array
{ok, [[1, 2], [3, 4]]} = py:eval(<<"import numpy as np; np.array([[1,2],[3,4]]).tolist()">>).
```

For best performance with large arrays, consider using `.tolist()` in Python before returning.

### Nested Structures

Nested data structures are recursively converted:

```erlang
%% Nested dict
{ok, #{<<"user">> := #{<<"name">> := <<"Alice">>, <<"age">> := 30}}} =
    py:eval(<<"{'user': {'name': 'Alice', 'age': 30}}">>).

%% List of tuples
{ok, [{1, <<"a">>}, {2, <<"b">>}]} = py:eval(<<"[(1, 'a'), (2, 'b')]">>).

%% Mixed nesting
{ok, #{<<"items">> := [1, 2, 3], <<"meta">> := {<<"ok">>, 200}}} =
    py:eval(<<"{'items': [1, 2, 3], 'meta': ('ok', 200)}">>).
```

### Map Keys

Erlang maps support any term as key, but Python dicts are more restricted:

```erlang
%% Erlang atom keys become Python strings
py:call(json, dumps, [#{foo => 1, bar => 2}]).
%% Python sees: {"foo": 1, "bar": 2}

%% Binary keys stay as strings
py:call(json, dumps, [#{<<"foo">> => 1}]).
%% Python sees: {"foo": 1}
```

When Python returns dicts, string keys become binaries:

```erlang
{ok, #{<<"foo">> := 1}} = py:eval(<<"{'foo': 1}">>).
```

### Keyword Arguments

Maps can be used for Python keyword arguments:

```erlang
%% Call with kwargs
{ok, Json} = py:call(json, dumps, [Data], #{indent => 2, sort_keys => true}).

%% Equivalent Python: json.dumps(data, indent=2, sort_keys=True)
```

## Unsupported Types

Some Python types cannot be directly converted:

| Python Type | Workaround |
|-------------|------------|
| `set` | Convert to list: `list(my_set)` |
| `frozenset` | Convert to tuple: `tuple(my_frozenset)` |
| `datetime` | Use `.isoformat()` or timestamp |
| `Decimal` | Use `float()` or `str()` |
| Custom objects | Implement `__iter__` or serialization |

### Example Workarounds

```erlang
%% Sets - convert to list in Python
{ok, [1, 2, 3]} = py:eval(<<"sorted(list({3, 1, 2}))">>).

%% Datetime - use ISO format
{ok, <<"2024-01-15T10:30:00">>} =
    py:eval(<<"from datetime import datetime; datetime(2024,1,15,10,30).isoformat()">>).

%% Decimal - convert to string for precision
{ok, <<"3.14159265358979323846">>} =
    py:eval(<<"from decimal import Decimal; str(Decimal('3.14159265358979323846'))">>).
```

## Performance Considerations

- **Large strings**: Binary conversion is efficient, but very large strings may cause memory pressure
- **Deep nesting**: Deeply nested structures require recursive traversal
- **Big integers**: Arbitrary precision integers work but large ones are slower
- **NumPy arrays**: Call `.tolist()` for explicit conversion; direct array conversion may be slower

For large data transfers, consider:
1. Using streaming for iterables
2. Serializing to JSON/msgpack in Python
3. Processing data in chunks
