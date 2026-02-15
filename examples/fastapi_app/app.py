# Copyright 2026 Benoit Chesneau
# Licensed under the Apache License, Version 2.0

"""FastAPI Example with Lifespan.

This example demonstrates:
- Using FastAPI with hornbeam
- ASGI lifespan protocol
- Erlang ETS integration

Run with:
    hornbeam:start("fastapi_app.app:app", #{worker_class => asgi, lifespan => on}).

Test with:
    curl http://localhost:8000/
    curl http://localhost:8000/items/42
    curl -X POST http://localhost:8000/items -d '{"name": "Widget", "price": 9.99}'
"""

from contextlib import asynccontextmanager

# Try to import FastAPI
try:
    from fastapi import FastAPI, HTTPException
    from pydantic import BaseModel
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False

# Import hornbeam utilities
try:
    from hornbeam_erlang import state_get, state_set, state_incr, state_delete
except ImportError:
    def state_get(k): return None
    def state_set(k, v): pass
    def state_incr(k, d=1): return d
    def state_delete(k): pass


if HAS_FASTAPI:
    class Item(BaseModel):
        name: str
        price: float
        description: str = ""

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        """FastAPI lifespan context manager.

        This is called during ASGI lifespan startup/shutdown.
        """
        # Startup
        print("FastAPI app starting up...")
        state_set("app_status", "running")
        state_set("startup_time", str(__import__('time').time()))

        yield

        # Shutdown
        print("FastAPI app shutting down...")
        state_set("app_status", "stopped")

    app = FastAPI(
        title="Hornbeam FastAPI Example",
        lifespan=lifespan
    )

    @app.get("/")
    async def root():
        """Root endpoint."""
        state_incr("requests")
        return {
            "message": "Hello from FastAPI on hornbeam!",
            "requests": state_get("requests") or 0,
            "status": state_get("app_status")
        }

    @app.get("/items/{item_id}")
    async def get_item(item_id: int):
        """Get an item by ID."""
        state_incr("requests")
        item = state_get(f"item:{item_id}")
        if item is None:
            raise HTTPException(status_code=404, detail="Item not found")
        return item

    @app.post("/items")
    async def create_item(item: Item):
        """Create a new item."""
        state_incr("requests")

        # Generate ID
        item_id = state_incr("item_counter", 1)

        # Store in ETS
        item_data = {
            "id": item_id,
            "name": item.name,
            "price": item.price,
            "description": item.description
        }
        state_set(f"item:{item_id}", item_data)

        return item_data

    @app.delete("/items/{item_id}")
    async def delete_item(item_id: int):
        """Delete an item."""
        state_incr("requests")
        if state_get(f"item:{item_id}") is None:
            raise HTTPException(status_code=404, detail="Item not found")
        state_delete(f"item:{item_id}")
        return {"deleted": item_id}

    @app.get("/stats")
    async def stats():
        """Get application statistics."""
        return {
            "requests": state_get("requests") or 0,
            "items_created": state_get("item_counter") or 0,
            "status": state_get("app_status"),
            "startup_time": state_get("startup_time")
        }

else:
    # Fallback if FastAPI not installed
    async def app(scope, receive, send):
        """Fallback ASGI app."""
        if scope['type'] == 'lifespan':
            msg = await receive()
            if msg['type'] == 'lifespan.startup':
                await send({'type': 'lifespan.startup.complete'})
            msg = await receive()
            if msg['type'] == 'lifespan.shutdown':
                await send({'type': 'lifespan.shutdown.complete'})
            return

        if scope['type'] == 'http':
            await send({
                'type': 'http.response.start',
                'status': 200,
                'headers': [(b'content-type', b'text/plain')]
            })
            await send({
                'type': 'http.response.body',
                'body': b'FastAPI not installed. Install with: pip install fastapi'
            })
