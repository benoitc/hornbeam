# Multi-App Demo - Admin Application (WSGI/Flask)
# Mounted at /admin

from flask import Flask, jsonify, request
import json

app = Flask(__name__)


@app.route("/")
def admin_root():
    """Admin dashboard root."""
    return jsonify({
        "app": "admin",
        "message": "Welcome to the Admin Panel",
        "script_name": request.environ.get("SCRIPT_NAME", ""),
        "path_info": request.environ.get("PATH_INFO", ""),
        "endpoints": ["/", "/dashboard", "/users", "/config"]
    })


@app.route("/dashboard")
def dashboard():
    """Admin dashboard."""
    return jsonify({
        "status": "ok",
        "server": "hornbeam",
        "mode": "multi-app"
    })


@app.route("/users")
def list_users():
    """List admin users (demo)."""
    return jsonify({
        "users": [
            {"id": 1, "name": "admin", "role": "superuser"},
            {"id": 2, "name": "operator", "role": "editor"}
        ]
    })


@app.route("/config")
def get_config():
    """Get server config info."""
    return jsonify({
        "python_path": request.environ.get("PYTHONPATH", ""),
        "server_name": request.environ.get("SERVER_NAME", ""),
        "server_port": request.environ.get("SERVER_PORT", ""),
        "wsgi_version": str(request.environ.get("wsgi.version", ""))
    })


# WSGI application callable
application = app
