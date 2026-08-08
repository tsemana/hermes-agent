"""Blocking-prompt answers must cross the compute-host process boundary.

Under dashboard.turn_isolation the whole turn — including the clarify/sudo/
secret/terminal.read waits in server._block() — runs inside the compute-host
child, but the client's ``*.respond`` RPC dispatches in the parent, against
the parent's own (empty) _pending map. Before the forwarding fix the parent
answered ``{"status": "expired"}``, the desktop spun forever, and the child
blocked until clarify_timeout with the user's answer lost.
"""

import io
import json
import threading

from tui_gateway.compute_host import ComputeHost
from tui_gateway.host_supervisor import HostSupervisor


def _emitted_frames(buf: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]


def test_child_prompt_respond_resolves_local_block():
    """A forwarded prompt.respond frame sets the child's local _block Event."""
    from tui_gateway import server

    buf = io.StringIO()
    host = ComputeHost(stdout=buf)
    ev = threading.Event()
    with server._prompt_lock:
        server._pending["rid-clarify"] = ("sid-1", ev)
    try:
        host.handle_frame(
            {
                "type": "prompt.respond",
                "request_id": "ctl-1",
                "respond_method": "clarify.respond",
                "params": {"request_id": "rid-clarify", "answer": "Option A"},
            }
        )
        assert ev.is_set(), "child _block Event was not released"
        with server._prompt_lock:
            assert server._answers.get("rid-clarify") == "Option A"
        acks = [f for f in _emitted_frames(buf) if f["type"] == "control.ack"]
        assert acks and acks[0]["request_id"] == "ctl-1"
        assert acks[0]["result"].get("status") == "ok"
    finally:
        with server._prompt_lock:
            server._pending.pop("rid-clarify", None)
            server._answers.pop("rid-clarify", None)


def test_child_prompt_respond_rejects_unknown_method():
    buf = io.StringIO()
    host = ComputeHost(stdout=buf)
    host.handle_frame(
        {
            "type": "prompt.respond",
            "request_id": "ctl-2",
            "respond_method": "config.set",
            "params": {"request_id": "rid-x", "answer": "boom"},
        }
    )
    errors = [f for f in _emitted_frames(buf) if f["type"] == "control.error"]
    assert errors and "unsupported respond method" in errors[0]["message"]


def _supervisor() -> HostSupervisor:
    return HostSupervisor(autostart=False)


def _clarify_request_rpc(rid: str) -> dict:
    return {
        "jsonrpc": "2.0",
        "method": "event",
        "params": {
            "type": "clarify.request",
            "session_id": "sid-1",
            "payload": {"request_id": rid, "question": "?"},
        },
    }


def test_supervisor_tracks_child_prompt_rids():
    sup = _supervisor()
    sup._handle_host_frame({"type": "rpc", "sid": "sid-1", "message": _clarify_request_rpc("rid-1")})
    assert "rid-1" in sup._child_prompt_rids

    expire = {
        "jsonrpc": "2.0",
        "method": "event",
        "params": {"type": "clarify.expire", "session_id": "sid-1", "payload": {"request_id": "rid-1"}},
    }
    sup._handle_host_frame({"type": "rpc", "sid": "sid-1", "message": expire})
    assert "rid-1" not in sup._child_prompt_rids


def test_supervisor_respond_prompt_round_trip(monkeypatch):
    sup = _supervisor()
    sup._handle_host_frame({"type": "rpc", "sid": "sid-1", "message": _clarify_request_rpc("rid-2")})

    sent: list[dict] = []

    def fake_send(frame: dict) -> None:
        sent.append(frame)
        # Ack immediately, as the child would after setting its local Event.
        sup._handle_host_frame(
            {
                "type": "control.ack",
                "request_id": frame["request_id"],
                "result": {"status": "ok"},
            }
        )

    monkeypatch.setattr(sup, "_send_frame", fake_send)
    monkeypatch.setattr(sup, "is_running", lambda: True)

    result = sup.respond_prompt(
        "clarify.respond", {"request_id": "rid-2", "answer": "Option A"}
    )
    assert result == {"status": "ok"}
    assert sent and sent[0]["type"] == "prompt.respond"
    assert sent[0]["respond_method"] == "clarify.respond"
    assert sent[0]["params"]["answer"] == "Option A"
    # Answered rid is dropped so a duplicate click falls back to "expired".
    assert "rid-2" not in sup._child_prompt_rids


def test_supervisor_respond_prompt_unknown_rid_returns_none():
    sup = _supervisor()
    assert (
        sup.respond_prompt("clarify.respond", {"request_id": "never-seen", "answer": "x"})
        is None
    )
