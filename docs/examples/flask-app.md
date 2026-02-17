---
title: Flask Application
description: Running Flask on Hornbeam with ETS caching
order: 20
---

# Flask Application Example

This example shows a Flask application running on Hornbeam with ETS-backed caching and metrics.

## Project Structure

```
flask_demo/
├── app.py           # Flask application
├── models.py        # Data models
└── requirements.txt # Python dependencies
```

## Application Code

```python
# app.py
from flask import Flask, jsonify, request
from hornbeam_erlang import state_get, state_set, state_incr, state_delete

app = Flask(__name__)

# ============================================================
# Middleware: Track request metrics
# ============================================================

@app.before_request
def track_request():
    state_incr('metrics:requests:total')
    state_incr(f'metrics:requests:{request.endpoint or "unknown"}')

# ============================================================
# Routes
# ============================================================

@app.route('/')
def index():
    views = state_incr('page:home:views')
    return jsonify({
        'message': 'Welcome to Flask on Hornbeam!',
        'views': views
    })

@app.route('/api/items', methods=['GET'])
def list_items():
    """List all items with caching."""
    # Check cache first
    cached = state_get('cache:items:list')
    if cached:
        return jsonify({'items': cached, 'cached': True})

    # Simulate database query
    items = fetch_items_from_db()

    # Cache for 60 seconds
    state_set('cache:items:list', items)

    return jsonify({'items': items, 'cached': False})

@app.route('/api/items/<int:item_id>', methods=['GET'])
def get_item(item_id):
    """Get single item with caching."""
    cache_key = f'cache:item:{item_id}'

    cached = state_get(cache_key)
    if cached:
        return jsonify({'item': cached, 'cached': True})

    item = fetch_item_from_db(item_id)
    if not item:
        return jsonify({'error': 'Not found'}), 404

    state_set(cache_key, item)
    return jsonify({'item': item, 'cached': False})

@app.route('/api/items', methods=['POST'])
def create_item():
    """Create item and invalidate cache."""
    data = request.get_json()

    # Generate ID using atomic counter
    item_id = state_incr('items:id_seq')

    item = {
        'id': item_id,
        'name': data.get('name'),
        'description': data.get('description')
    }

    # Store in ETS (simulating database)
    state_set(f'item:{item_id}', item)

    # Invalidate list cache
    state_delete('cache:items:list')

    return jsonify({'item': item}), 201

@app.route('/api/items/<int:item_id>', methods=['DELETE'])
def delete_item(item_id):
    """Delete item and invalidate caches."""
    state_delete(f'item:{item_id}')
    state_delete(f'cache:item:{item_id}')
    state_delete('cache:items:list')

    return '', 204

# ============================================================
# Metrics endpoint
# ============================================================

@app.route('/metrics')
def metrics():
    """Return application metrics."""
    return jsonify({
        'requests': {
            'total': state_get('metrics:requests:total') or 0,
        },
        'items': {
            'count': len(list_all_items()),
            'id_seq': state_get('items:id_seq') or 0
        },
        'cache': {
            'items_list_cached': state_get('cache:items:list') is not None
        }
    })

# ============================================================
# Rate limiting example
# ============================================================

@app.route('/api/limited')
def rate_limited_endpoint():
    """Endpoint with rate limiting."""
    # Get client IP
    client_ip = request.remote_addr

    # Rate limit key (per minute)
    from datetime import datetime
    minute = datetime.now().strftime('%Y%m%d%H%M')
    limit_key = f'ratelimit:{client_ip}:{minute}'

    # Check and increment
    count = state_incr(limit_key)

    if count > 100:  # 100 requests per minute
        return jsonify({'error': 'Rate limit exceeded'}), 429

    return jsonify({'remaining': 100 - count})

# ============================================================
# Helper functions
# ============================================================

def fetch_items_from_db():
    """Simulate database fetch."""
    return list_all_items()

def fetch_item_from_db(item_id):
    """Simulate database fetch."""
    return state_get(f'item:{item_id}')

def list_all_items():
    """List all items from ETS."""
    from hornbeam_erlang import state_keys
    keys = state_keys('item:')
    items = []
    for key in keys:
        if not key.startswith('items:'):  # Skip metadata keys
            item = state_get(key)
            if item:
                items.append(item)
    return items

# ============================================================
# WSGI application
# ============================================================

application = app

# For gunicorn compatibility
if __name__ == '__main__':
    app.run(debug=True)
```

## Running with Hornbeam

```erlang
%% Start Erlang shell
rebar3 shell

%% Start Hornbeam
hornbeam:start("app:application", #{
    pythonpath => ["flask_demo"],
    workers => 4,
    timeout => 30000
}).
```

## Running with Gunicorn (for comparison)

```bash
cd flask_demo
pip install gunicorn
gunicorn app:application
```

## Testing

```bash
# Create items
curl -X POST http://localhost:8000/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "Item 1", "description": "First item"}'

curl -X POST http://localhost:8000/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "Item 2", "description": "Second item"}'

# List items (first call - not cached)
curl http://localhost:8000/api/items
# {"items": [...], "cached": false}

# List items (second call - cached)
curl http://localhost:8000/api/items
# {"items": [...], "cached": true}

# Get single item
curl http://localhost:8000/api/items/1

# Check metrics
curl http://localhost:8000/metrics

# Test rate limiting
for i in {1..105}; do curl http://localhost:8000/api/limited; done
```

## Requirements

```
# requirements.txt
flask>=2.0
```

## Key Features Demonstrated

1. **Atomic counters** for IDs and metrics
2. **ETS caching** with cache invalidation
3. **Rate limiting** using ETS
4. **Request tracking** for metrics
5. **Gunicorn compatibility** (fallback when not on Hornbeam)

## Making It Gunicorn-Compatible

For code that works on both Hornbeam and gunicorn:

```python
# Check if running on Hornbeam
try:
    from hornbeam_erlang import state_get, state_set, state_incr
    ON_HORNBEAM = True
except ImportError:
    ON_HORNBEAM = False

    # Fallback implementations
    _cache = {}

    def state_get(key):
        return _cache.get(key)

    def state_set(key, value):
        _cache[key] = value

    def state_incr(key, delta=1):
        _cache[key] = _cache.get(key, 0) + delta
        return _cache[key]
```

## Next Steps

- [FastAPI Example](./fastapi-app.md) - Async application
- [Erlang Integration Guide](../guides/erlang-integration.md) - More ETS patterns
