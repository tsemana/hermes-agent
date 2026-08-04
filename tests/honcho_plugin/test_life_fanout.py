"""Fork: the read-down [life memory] fan-out in search_context.

The work agent (Helm) reads the life Honcho host through the :8010
read-only proxy, which denies /messages — so the life side must always
come from the context/representation path (_life_fetch_context), never
from the message search. These tests pin that contract across upstream
rewrites of search_context.
"""

from __future__ import annotations

from unittest.mock import MagicMock

from plugins.memory.honcho.session import HonchoSessionManager


def _manager_with_stub_session(monkeypatch):
    mgr = HonchoSessionManager.__new__(HonchoSessionManager)
    session = MagicMock()
    session.assistant_peer_id = "assistant"
    mgr._cache = {"sk": session}
    mgr._resolve_peer_id = lambda _session, _peer: "peer-1"
    # `honcho` is a read-only property routing through get_honcho_client().
    honcho = MagicMock()
    monkeypatch.setattr(HonchoSessionManager, "honcho", property(lambda self: honcho))
    mgr.honcho.search  # touch to keep the stub referenced
    return mgr


def test_search_context_appends_life_memory_block(monkeypatch):
    mgr = _manager_with_stub_session(monkeypatch)
    msg = MagicMock()
    msg.content = "local fact"
    msg.peer_id = "tony"
    msg.session_id = "s1"
    mgr.honcho.search.return_value = [msg]
    mgr._life_fetch_context = lambda search_query=None: {
        "representation": "life rep",
        "card": ["life fact"],
    }

    out = mgr.search_context("sk", "what about Phoenix?")

    assert "local fact" in out
    assert "[life memory]" in out
    assert "life rep" in out
    assert "- life fact" in out


def test_life_fanout_runs_even_when_local_search_is_empty(monkeypatch):
    mgr = _manager_with_stub_session(monkeypatch)
    mgr.honcho.search.return_value = []
    mgr._life_fetch_context = lambda search_query=None: {
        "representation": "life only",
        "card": [],
    }

    out = mgr.search_context("sk", "anything")

    assert out.startswith("[life memory]")
    assert "life only" in out


def test_life_fanout_failure_never_breaks_local_results(monkeypatch):
    mgr = _manager_with_stub_session(monkeypatch)
    msg = MagicMock()
    msg.content = "local fact"
    msg.peer_id = "tony"
    msg.session_id = "s1"
    mgr.honcho.search.return_value = [msg]

    def _boom(search_query=None):
        raise RuntimeError("life host down")

    mgr._life_fetch_context = _boom

    out = mgr.search_context("sk", "query")

    assert "local fact" in out
    assert "[life memory]" not in out
