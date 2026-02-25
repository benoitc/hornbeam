# Multi-App Demo - API Application (ASGI/FastAPI)
# Mounted at /api

from fastapi import FastAPI, Request
from pydantic import BaseModel
from typing import List
import json

app = FastAPI(
    title="Multi-App Demo API",
    root_path="/api"  # Will be overridden by Hornbeam mount
)

# In-memory storage for demo
items_db = {}
counter = {"value": 0}


class Item(BaseModel):
    name: str
    description: str = ""
    price: float


@app.get("/")
async def api_root(request: Request):
    """API root - shows mount info."""
    return {
        "app": "api",
        "message": "Welcome to the API",
        "root_path": request.scope.get("root_path", ""),
        "path": request.scope.get("path", ""),
        "endpoints": ["/", "/items", "/items/{id}", "/stats"]
    }


@app.get("/items")
async def list_items():
    """List all items."""
    return {"items": list(items_db.values()), "count": len(items_db)}


@app.post("/items")
async def create_item(item: Item):
    """Create a new item."""
    counter["value"] += 1
    item_id = counter["value"]
    item_dict = item.dict()
    item_dict["id"] = item_id
    items_db[item_id] = item_dict
    return {"created": item_dict}


@app.get("/items/{item_id}")
async def get_item(item_id: int):
    """Get an item by ID."""
    if item_id not in items_db:
        return {"error": "Item not found"}, 404
    return items_db[item_id]


@app.delete("/items/{item_id}")
async def delete_item(item_id: int):
    """Delete an item."""
    if item_id not in items_db:
        return {"error": "Item not found"}, 404
    deleted = items_db.pop(item_id)
    return {"deleted": deleted}


@app.get("/stats")
async def get_stats():
    """Get API statistics."""
    return {
        "total_items": len(items_db),
        "total_created": counter["value"]
    }
