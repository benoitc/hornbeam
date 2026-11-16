"""Strict HTTP boundary probe for the native ASGI regression suite."""

import json
from collections.abc import Awaitable, Callable
from http.cookies import SimpleCookie

Receive = Callable[[], Awaitable[dict[str, object]]]
Send = Callable[[dict[str, object]], Awaitable[None]]

# State only: no loop-affine objects, so the probes work across pool loops.
_lifecycle: dict[str, bytes] = {}


async def lifecycle(path: str, receive: Receive, send: Send) -> None:
    _, _, action, name = path.split("/")
    if action == "status":
        await send({"type": "http.response.start", "status": 200})
        await send({"type": "http.response.body", "body": _lifecycle.get(name, b"")})
        return

    event = await receive()
    assert event["type"] == "http.request" and not event["more_body"]
    _lifecycle[name] = b"waiting"
    if name in {"complete", "stream"}:
        await send({"type": "http.response.start", "status": 200})
        await send({"type": "http.response.body", "body": b"ok",
                    "more_body": name == "stream"})
    try:
        assert await receive() == {"type": "http.disconnect"}
        _lifecycle[name] = b"done"
    except BaseException as exc:
        _lifecycle[name] = repr(exc).encode()
        raise


def parse_headers(value: object) -> list[tuple[bytes, bytes]]:
    assert isinstance(value, list)
    headers: list[tuple[bytes, bytes]] = []
    for pair in value:
        assert isinstance(pair, (tuple, list)) and len(pair) == 2
        name, content = pair
        assert isinstance(name, bytes) and isinstance(content, bytes)
        headers.append((name, content))
    return headers


async def application(scope: dict[str, object], receive: Receive, send: Send) -> None:
    assert all(isinstance(key, str) for key in scope)
    for field in ("type", "http_version", "method", "scheme", "path", "root_path"):
        assert isinstance(scope[field], str), field
    assert scope["type"] == "http"
    asgi = scope["asgi"]
    assert isinstance(asgi, dict)
    assert asgi["version"] == "3.0"
    assert asgi["spec_version"] == "2.4"
    for field in ("server", "client"):
        address = scope[field]
        assert isinstance(address, (tuple, list)) and len(address) == 2
        assert isinstance(address[0], str) and isinstance(address[1], int)
    raw_path, query = scope["raw_path"], scope["query_string"]
    assert isinstance(raw_path, bytes) and isinstance(query, bytes)
    headers = parse_headers(scope["headers"])
    extensions = scope["extensions"]
    assert isinstance(extensions, dict)

    if scope["path"].startswith("/lifecycle/"):
        await lifecycle(scope["path"], receive, send)
        return

    if scope["path"] == "/echo":
        chunks: list[bytes] = []
        while True:
            event = await receive()
            body = event["body"]
            assert isinstance(body, bytes)
            chunks.append(body)
            if not event.get("more_body", False):
                break
        result = b"".join(chunks)
    elif scope["path"] == "/cookie":
        cookies: SimpleCookie[str] = SimpleCookie()
        # Cookie syntax is ASCII; locating the header must use ASGI byte names.
        for name, value in headers:
            if name == b"cookie":
                cookies.load(value.decode("ascii"))
        result = cookies["probe"].value.encode("ascii")
    else:
        result = json.dumps(
            {
                "path": scope["path"],
                "raw_path": raw_path.decode("ascii"),
                "query": query.decode("ascii"),
                "headers": [[name.hex(), value.hex()] for name, value in headers],
            },
            ensure_ascii=True,
        ).encode("ascii")
    await send({"type": "http.response.start", "status": 200})
    await send({"type": "http.response.body", "body": result})
