# Copyright 2026 Benoit Chesneau
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Dirty execution runner for Python apps.

This module handles execution of Python app actions called via
hornbeam_dirty:execute/4 from Erlang.

App path format: "module.submodule:ClassName" or "module:function"

Examples:
    # Class-based app
    "myapp.ml:MLService" -> calls MLService.action(args, **kwargs)

    # Function-based app
    "myapp.handlers:handle" -> calls handle(action, args, kwargs)
"""

import importlib
import inspect
import sys
from typing import Any, Dict, Generator, List, Optional, Tuple

# Generator storage for streaming
_generators: Dict[str, Generator] = {}
_gen_counter = 0

# Registered Python hook handlers
_registered_hooks: Dict[str, Any] = {}


def _load_app(app_path: str) -> Tuple[Any, bool]:
    """Load an app from path.

    Args:
        app_path: "module:name" format

    Returns:
        (app_object, is_class) tuple
    """
    if ':' not in app_path:
        raise ValueError(f"Invalid app path: {app_path} (expected 'module:name')")

    module_path, name = app_path.rsplit(':', 1)

    # Import module
    if module_path in sys.modules:
        module = sys.modules[module_path]
    else:
        module = importlib.import_module(module_path)

    # Get the object
    obj = getattr(module, name)

    # Check if it's a class
    is_class = inspect.isclass(obj)

    return obj, is_class


def execute(app_path: str, action: str, args: List[Any], kwargs: Dict[str, Any]) -> Any:
    """Execute an action on an app.

    Args:
        app_path: "module:name" format
        action: Action/method name
        args: Positional arguments
        kwargs: Keyword arguments

    Returns:
        Result of the action
    """
    obj, is_class = _load_app(app_path)

    if is_class:
        # Instantiate class and call method
        instance = obj()
        method = getattr(instance, action)
        return method(*args, **kwargs)
    else:
        # Call function with action as first arg
        return obj(action, args, kwargs)


def stream_start(app_path: str, action: str, args: List[Any], kwargs: Dict[str, Any]) -> Tuple[str, str]:
    """Start a streaming execution.

    The app should return a generator.

    Args:
        app_path: "module:name" format
        action: Action/method name
        args: Positional arguments
        kwargs: Keyword arguments

    Returns:
        ('ok', generator_id) or ('error', reason)
    """
    global _gen_counter

    try:
        obj, is_class = _load_app(app_path)

        if is_class:
            instance = obj()
            method = getattr(instance, action)
            result = method(*args, **kwargs)
        else:
            result = obj(action, args, kwargs)

        # Result should be a generator
        if not inspect.isgenerator(result):
            # If not a generator, wrap single value
            def single_value_gen():
                yield result
            result = single_value_gen()

        # Store generator
        _gen_counter += 1
        gen_id = f"gen_{_gen_counter}"
        _generators[gen_id] = result

        return ('ok', gen_id)

    except Exception as e:
        return ('error', str(e))


def stream_next(gen_id: str) -> Tuple[str, Any]:
    """Get next value from a generator.

    Args:
        gen_id: Generator ID from stream_start

    Returns:
        ('ok', value) or 'done' or ('error', reason)
    """
    if gen_id not in _generators:
        return ('error', 'generator_not_found')

    gen = _generators[gen_id]

    try:
        value = next(gen)
        return ('ok', value)
    except StopIteration:
        # Clean up
        del _generators[gen_id]
        return 'done'
    except Exception as e:
        # Clean up on error
        del _generators[gen_id]
        return ('error', str(e))


def stream_close(gen_id: str) -> str:
    """Close a generator early.

    Args:
        gen_id: Generator ID

    Returns:
        'ok'
    """
    if gen_id in _generators:
        gen = _generators[gen_id]
        gen.close()
        del _generators[gen_id]
    return 'ok'


# =============================================================================
# Registered Python Hooks (for lifespan registration)
# =============================================================================

def register_handler(app_path: str, handler: Any) -> str:
    """Register a Python handler for an app path.

    Called internally when Python registers a hook.
    The handler can be:
    - A callable (function or lambda)
    - A class (will be instantiated per call)
    - An instance with methods

    Args:
        app_path: App identifier (e.g., "myservice")
        handler: The handler (callable, class, or instance)

    Returns:
        'ok'
    """
    _registered_hooks[app_path] = handler
    return 'ok'


def unregister_handler(app_path: str) -> str:
    """Unregister a Python handler.

    Args:
        app_path: App identifier

    Returns:
        'ok'
    """
    if app_path in _registered_hooks:
        del _registered_hooks[app_path]
    return 'ok'


def execute_registered(app_path: str, action: str, args: List[Any], kwargs: Dict[str, Any]) -> Any:
    """Execute a registered Python handler.

    Called by Erlang when it finds a Python hook.

    Args:
        app_path: App identifier
        action: Action/method name
        args: Positional arguments
        kwargs: Keyword arguments

    Returns:
        Result of the handler
    """
    if app_path not in _registered_hooks:
        raise ValueError(f"No handler registered for {app_path}")

    handler = _registered_hooks[app_path]

    # If handler is a class, instantiate and call method
    if inspect.isclass(handler):
        instance = handler()
        method = getattr(instance, action)
        return method(*args, **kwargs)

    # If handler is an instance with the method
    elif hasattr(handler, action):
        method = getattr(handler, action)
        return method(*args, **kwargs)

    # If handler is callable (function), call it with action
    elif callable(handler):
        return handler(action, args, kwargs)

    else:
        raise TypeError(f"Handler for {app_path} is not callable")


def stream_registered_start(app_path: str, action: str, args: List[Any], kwargs: Dict[str, Any]) -> Tuple[str, str]:
    """Start streaming from a registered Python handler.

    Args:
        app_path: App identifier
        action: Action/method name
        args: Positional arguments
        kwargs: Keyword arguments

    Returns:
        ('ok', generator_id) or ('error', reason)
    """
    global _gen_counter

    try:
        if app_path not in _registered_hooks:
            return ('error', f"No handler registered for {app_path}")

        handler = _registered_hooks[app_path]

        # Get the result
        if inspect.isclass(handler):
            instance = handler()
            method = getattr(instance, action)
            result = method(*args, **kwargs)
        elif hasattr(handler, action):
            method = getattr(handler, action)
            result = method(*args, **kwargs)
        elif callable(handler):
            result = handler(action, args, kwargs)
        else:
            return ('error', f"Handler for {app_path} is not callable")

        # Result should be a generator
        if not inspect.isgenerator(result):
            def single_value_gen():
                yield result
            result = single_value_gen()

        # Store generator
        _gen_counter += 1
        gen_id = f"gen_{_gen_counter}"
        _generators[gen_id] = result

        return ('ok', gen_id)

    except Exception as e:
        return ('error', str(e))


def is_registered(app_path: str) -> bool:
    """Check if a handler is registered for app_path.

    Args:
        app_path: App identifier

    Returns:
        True if registered, False otherwise
    """
    return app_path in _registered_hooks
