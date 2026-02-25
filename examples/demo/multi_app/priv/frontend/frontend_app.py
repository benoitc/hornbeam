# Multi-App Demo - Frontend Application (WSGI)
# Mounted at / (root)

import json


def application(environ, start_response):
    """Simple WSGI frontend serving HTML."""
    path = environ.get("PATH_INFO", "/")
    script_name = environ.get("SCRIPT_NAME", "")

    if path == "/" or path == "":
        # Home page with links to all apps
        body = """<!DOCTYPE html>
<html>
<head>
    <title>Hornbeam Multi-App Demo</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        .card { background: #f5f5f5; border-radius: 8px; padding: 20px; margin: 20px 0; }
        .card h2 { margin-top: 0; color: #555; }
        a { color: #0066cc; }
        code { background: #e0e0e0; padding: 2px 6px; border-radius: 3px; }
        ul { line-height: 1.8; }
    </style>
</head>
<body>
    <h1>Hornbeam Multi-App Demo</h1>
    <p>This demo shows multiple Python applications mounted at different URL prefixes.</p>

    <div class="card">
        <h2>API (FastAPI/ASGI) - <a href="/api">/api</a></h2>
        <p>Async REST API for items management.</p>
        <ul>
            <li><a href="/api">/api</a> - API root</li>
            <li><a href="/api/items">/api/items</a> - List items</li>
            <li><a href="/api/stats">/api/stats</a> - API statistics</li>
        </ul>
    </div>

    <div class="card">
        <h2>Admin (Flask/WSGI) - <a href="/admin">/admin</a></h2>
        <p>Admin dashboard for system management.</p>
        <ul>
            <li><a href="/admin">/admin</a> - Admin root</li>
            <li><a href="/admin/dashboard">/admin/dashboard</a> - Dashboard</li>
            <li><a href="/admin/users">/admin/users</a> - User management</li>
            <li><a href="/admin/config">/admin/config</a> - Server config</li>
        </ul>
    </div>

    <div class="card">
        <h2>Frontend (WSGI) - <a href="/">/</a></h2>
        <p>This page! A simple WSGI app serving the root.</p>
        <ul>
            <li><a href="/">/</a> - Home (this page)</li>
            <li><a href="/about">/about</a> - About page</li>
            <li><a href="/health">/health</a> - Health check</li>
        </ul>
    </div>

    <div class="card">
        <h2>How It Works</h2>
        <p>Hornbeam routes requests based on URL prefix:</p>
        <ul>
            <li><code>/api/*</code> -> FastAPI (ASGI) with <code>root_path=/api</code></li>
            <li><code>/admin/*</code> -> Flask (WSGI) with <code>SCRIPT_NAME=/admin</code></li>
            <li><code>/*</code> -> This frontend (WSGI) catches everything else</li>
        </ul>
    </div>
</body>
</html>"""
        status = "200 OK"
        headers = [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Length", str(len(body.encode())))
        ]
        start_response(status, headers)
        return [body.encode()]

    elif path == "/about":
        body = json.dumps({
            "app": "frontend",
            "description": "Hornbeam Multi-App Demo",
            "version": "1.0.0",
            "mounts": {
                "/api": "FastAPI (ASGI)",
                "/admin": "Flask (WSGI)",
                "/": "Frontend (WSGI)"
            }
        }, indent=2)
        status = "200 OK"
        headers = [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body)))
        ]
        start_response(status, headers)
        return [body.encode()]

    elif path == "/health":
        body = json.dumps({"status": "healthy", "app": "frontend"})
        status = "200 OK"
        headers = [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body)))
        ]
        start_response(status, headers)
        return [body.encode()]

    else:
        # 404 for other paths
        body = json.dumps({
            "error": "Not Found",
            "path": path,
            "app": "frontend"
        })
        status = "404 Not Found"
        headers = [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body)))
        ]
        start_response(status, headers)
        return [body.encode()]
