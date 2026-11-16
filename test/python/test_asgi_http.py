"""Focused worker regressions. Run with PYTHONPATH=priv and pytest."""

import asyncio
from collections.abc import Awaitable, Callable

import hornbeam_asgi_worker as worker
import pytest


@pytest.mark.parametrize(
    "body", [b"hello", "café".encode(), "雪".encode(), b"\xff\x00\x80", b""]
)
def test_inline_body__should_preserve_bytes(body: bytes) -> None:
    receiver = worker.BodyReceiver(("body", body))
    message = asyncio.run(receiver.receive())
    assert message == {"type": "http.request", "body": body, "more_body": False}
    assert isinstance(message["body"], bytes)


@pytest.mark.parametrize("body", ["café", "雪"])
def test_inline_body__untagged_text__should_reject_instead_of_corrupt(
    body: str,
) -> None:
    with pytest.raises(TypeError, match="must be bytes"):
        worker.BodyReceiver(("body", body))


@pytest.mark.parametrize("path", ["/caf%C3%A9", b"/caf%C3%A9", b"/bad\xff"])
@pytest.mark.parametrize("with_extensions", [True, False])
def test_handle_asgi__should_preserve_byte_fields_and_decode_path(
    monkeypatch: pytest.MonkeyPatch, path: str | bytes, with_extensions: bool
) -> None:
    owner = object()
    seen: list[object] = []
    headers = [[b"cookie", b"probe=yes"], [b"x-raw", b"\xff\x00\x80"]]
    scope: dict[str, object] = {
        "type": "http",
        "path": path,
        "root_path": b"",
        "raw_path": b"/caf%C3%A9",
        "query_string": b"name=caf%C3%A9",
        "headers": headers,
    }
    if with_extensions:
        scope["extensions"] = {"http.response.early_hints": {}}

    async def app(
        app_scope: dict[str, object],
        receive: Callable[[], Awaitable[dict[str, object]]],
        send: Callable[[dict[str, object]], Awaitable[None]],
    ) -> None:
        assert app_scope is scope
        extensions = app_scope.get("extensions", {})
        assert isinstance(extensions, dict)
        assert ("http.response.early_hints" in extensions) == with_extensions
        assert app_scope["path"] == ("/bad�" if path == b"/bad\xff" else "/café")
        assert app_scope["root_path"] == ""
        assert app_scope["raw_path"] == b"/caf%C3%A9"
        assert app_scope["query_string"] == b"name=caf%C3%A9"
        assert app_scope["headers"] == headers
        assert (await receive())["body"] == "雪".encode()
        await send({"type": "http.response.start", "status": 200})
        await send({"type": "http.response.body", "body": b"ok"})

    def record(pid: object, message: object) -> None:
        assert pid is owner
        seen.append(message)

    monkeypatch.setattr(worker, "HAS_ERLANG", True)
    monkeypatch.setattr(worker, "_get_app", lambda module, name: app)
    monkeypatch.setattr(worker, "_erlang_send", record)
    asyncio.run(
        worker.handle_asgi(owner, "probe", "app", scope, ("body", "雪".encode()))
    )
    assert seen == [(b"start_response", 200, [], b"ok"), b"fin"]
