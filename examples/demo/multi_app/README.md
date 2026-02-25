# Hornbeam Multi-App Demo

This example demonstrates mounting multiple Python applications at different URL prefixes, each with its own virtual environment.

## Architecture

```
/api/*    -> FastAPI (ASGI) - REST API with fastapi venv
/admin/*  -> Flask (WSGI)   - Admin panel with flask venv
/*        -> Frontend (WSGI) - Landing page, no extra deps
```

## Running with Docker

Build and start:

```bash
cd examples/demo
docker compose up -d multi-app
```

The server will be available at http://localhost:9004

## Testing

Test all three mounts:

```bash
# Frontend (root mount)
curl http://localhost:9004/
curl http://localhost:9004/about

# FastAPI API
curl http://localhost:9004/api
curl http://localhost:9004/api/items
curl -X POST http://localhost:9004/api/items \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","price":9.99}'

# Flask Admin
curl http://localhost:9004/admin
curl http://localhost:9004/admin/dashboard
```

## Running Locally

Without Docker, you need to:

1. Build the release:
   ```bash
   cd examples/demo/multi_app
   rebar3 release
   ```

2. Start the release:
   ```bash
   _build/default/rel/multi_app/bin/multi_app foreground
   ```

The app will automatically create virtual environments and install dependencies on first run.

## Project Structure

```
multi_app/
├── src/
│   ├── multi_app_app.erl    # OTP application (starts Hornbeam)
│   └── multi_app_sup.erl    # Supervisor
├── priv/
│   ├── api/
│   │   ├── api_app.py       # FastAPI application
│   │   └── requirements.txt # fastapi, pydantic
│   ├── admin/
│   │   ├── admin_app.py     # Flask application
│   │   └── requirements.txt # flask
│   └── frontend/
│       └── frontend_app.py  # Simple WSGI application
├── config/
│   └── sys.config           # Erlang config
├── Dockerfile
└── rebar.config
```

## How It Works

The `multi_app_app.erl` starts Hornbeam with multiple mounts:

```erlang
hornbeam:start(#{
    mounts => [
        {"/api", "api_app:app", #{
            worker_class => asgi,
            venv => ApiVenv,
            pythonpath => [ApiDir]
        }},
        {"/admin", "admin_app:application", #{
            worker_class => wsgi,
            venv => AdminVenv,
            pythonpath => [AdminDir]
        }},
        {"/", "frontend_app:application", #{
            worker_class => wsgi,
            pythonpath => [FrontendDir]
        }}
    ]
}).
```

Each mount can have:
- Its own `venv` - virtual environment path
- Its own `pythonpath` - directories to add to Python's sys.path
- Its own `worker_class` - wsgi or asgi
- Its own `workers` and `timeout` settings

## Cleanup

```bash
docker compose down multi-app
```
