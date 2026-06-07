#!/usr/bin/env python3
"""Session usage telemetry tool.

Provides an agent-callable view of the live AIAgent usage counters so closeout
workflows can include `/usage`-style telemetry without asking the user to run a
slash command and paste the output back into the conversation.
"""

from __future__ import annotations

import json
from datetime import datetime
from typing import Any


def _int_attr(obj: Any, name: str, default: int = 0) -> int:
    try:
        return int(getattr(obj, name, default) or 0)
    except Exception:
        return default


def _iso_datetime(value: Any) -> str | None:
    if isinstance(value, datetime):
        return value.isoformat()
    return None


def _elapsed_seconds(start: Any) -> int | None:
    if not isinstance(start, datetime):
        return None
    try:
        return max(0, int((datetime.now() - start).total_seconds()))
    except Exception:
        return None


def _cost_snapshot(agent: Any, usage: dict[str, Any]) -> dict[str, Any]:
    """Return best-effort cost metadata without making network calls."""
    try:
        from agent.usage_pricing import CanonicalUsage, estimate_usage_cost

        cost = estimate_usage_cost(
            usage.get("model", ""),
            CanonicalUsage(
                input_tokens=usage["tokens"]["input"],
                output_tokens=usage["tokens"]["output"],
                cache_read_tokens=usage["tokens"]["cache_read"],
                cache_write_tokens=usage["tokens"]["cache_write"],
                request_count=usage.get("api_calls", 1) or 1,
            ),
            provider=getattr(agent, "provider", None),
            base_url=getattr(agent, "base_url", None),
        )
        snapshot: dict[str, Any] = {
            "status": getattr(cost, "status", "unknown") or "unknown",
            "source": getattr(cost, "source", "unknown") or "unknown",
        }
        amount = getattr(cost, "amount_usd", None)
        if amount is not None:
            snapshot["usd"] = float(amount)
        return snapshot
    except Exception:
        return {"status": "unknown", "source": "unavailable"}


def collect_session_usage(agent: Any) -> dict[str, Any]:
    """Collect live usage counters from an AIAgent-like object.

    The shape intentionally mirrors the TUI gateway's ``session.usage`` RPC but
    is closeout-ready: it also includes session id/start/elapsed and nests token
    counters under a stable ``tokens`` key.
    """
    start = getattr(agent, "session_start", None)
    tokens = {
        "input": _int_attr(agent, "session_input_tokens", _int_attr(agent, "session_prompt_tokens")),
        "cache_read": _int_attr(agent, "session_cache_read_tokens"),
        "cache_write": _int_attr(agent, "session_cache_write_tokens"),
        "output": _int_attr(agent, "session_output_tokens", _int_attr(agent, "session_completion_tokens")),
        "reasoning": _int_attr(agent, "session_reasoning_tokens"),
        "prompt_total": _int_attr(agent, "session_prompt_tokens"),
        "completion": _int_attr(agent, "session_completion_tokens"),
        "total": _int_attr(agent, "session_total_tokens"),
    }
    usage: dict[str, Any] = {
        "session_id": getattr(agent, "session_id", "") or "",
        "started_at": _iso_datetime(start),
        "elapsed_seconds": _elapsed_seconds(start),
        "model": getattr(agent, "model", "") or "",
        "provider": getattr(agent, "provider", "") or "",
        "tokens": tokens,
        "api_calls": _int_attr(agent, "session_api_calls"),
    }

    compressor = getattr(agent, "context_compressor", None)
    if compressor is not None:
        context_used = _int_attr(compressor, "last_prompt_tokens", tokens["total"])
        context_max = _int_attr(compressor, "context_length")
        context: dict[str, Any] = {
            "used": context_used,
            "max": context_max,
            "percent": round(context_used / context_max * 100) if context_max else 0,
            "compressions": _int_attr(compressor, "compression_count"),
        }
        usage["context"] = context

    usage["cost"] = _cost_snapshot(agent, usage)
    accumulated_cost = getattr(agent, "session_estimated_cost_usd", None)
    if isinstance(accumulated_cost, (int, float)) and accumulated_cost > 0:
        usage["cost"] = {
            "status": getattr(agent, "session_cost_status", None) or usage["cost"].get("status", "estimated"),
            "source": getattr(agent, "session_cost_source", None) or usage["cost"].get("source", "session_accumulator"),
            "usd": float(accumulated_cost),
        }
    return usage


def session_usage_tool(agent: Any = None) -> str:
    """Return live session usage telemetry as JSON."""
    if agent is None:
        return json.dumps(
            {
                "success": False,
                "error": "Session usage is not available because no live agent was provided.",
            },
            ensure_ascii=False,
        )
    return json.dumps(
        {"success": True, "usage": collect_session_usage(agent)},
        ensure_ascii=False,
    )


def check_session_usage_requirements() -> bool:
    """Session usage has no external requirements."""
    return True


SESSION_USAGE_SCHEMA = {
    "name": "session_usage",
    "description": (
        "Retrieve live usage telemetry for the current Hermes session. Use this "
        "during closeout/wrap-session workflows to include elapsed time, token "
        "counts, API calls, context usage, and estimated cost without asking the "
        "user to run /usage or paste output. Takes no arguments."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "required": [],
    },
}


from tools.registry import registry  # noqa: E402

registry.register(
    name="session_usage",
    toolset="session",
    schema=SESSION_USAGE_SCHEMA,
    handler=lambda args, **kw: session_usage_tool(agent=kw.get("agent")),
    check_fn=check_session_usage_requirements,
    emoji="📊",
)
