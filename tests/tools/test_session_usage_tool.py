import json
from datetime import datetime, timedelta
from types import SimpleNamespace

from tools.session_usage_tool import collect_session_usage, session_usage_tool


class DummyCompressor:
    last_prompt_tokens = 1234
    context_length = 10000
    compression_count = 2


class DummyAgent:
    model = "test/model"
    provider = "test-provider"
    base_url = "https://example.test/v1"
    session_id = "session-123"
    session_start = datetime.now() - timedelta(seconds=65)
    session_input_tokens = 100
    session_output_tokens = 25
    session_cache_read_tokens = 10
    session_cache_write_tokens = 5
    session_reasoning_tokens = 7
    session_prompt_tokens = 115
    session_completion_tokens = 32
    session_total_tokens = 147
    session_api_calls = 3
    context_compressor = DummyCompressor()


class DummyAgentWithAccumulatedCost(DummyAgent):
    session_estimated_cost_usd = 0.1234
    session_cost_status = "estimated"
    session_cost_source = "session_accumulator"


def test_collect_session_usage_returns_closeout_ready_snapshot():
    usage = collect_session_usage(DummyAgent())

    assert usage["session_id"] == "session-123"
    assert usage["model"] == "test/model"
    assert usage["provider"] == "test-provider"
    assert usage["tokens"] == {
        "input": 100,
        "cache_read": 10,
        "cache_write": 5,
        "output": 25,
        "reasoning": 7,
        "prompt_total": 115,
        "completion": 32,
        "total": 147,
    }
    assert usage["api_calls"] == 3
    assert usage["elapsed_seconds"] >= 60
    assert usage["context"] == {
        "used": 1234,
        "max": 10000,
        "percent": 12,
        "compressions": 2,
    }
    assert usage["cost"]["status"] in {"estimated", "included", "unknown"}


def test_collect_session_usage_prefers_accumulated_session_cost():
    usage = collect_session_usage(DummyAgentWithAccumulatedCost())

    assert usage["cost"] == {
        "status": "estimated",
        "source": "session_accumulator",
        "usd": 0.1234,
    }


def test_session_usage_tool_returns_json_and_requires_agent():
    payload = json.loads(session_usage_tool(DummyAgent()))

    assert payload["success"] is True
    assert payload["usage"]["session_id"] == "session-123"

    missing = json.loads(session_usage_tool(None))
    assert missing["success"] is False
    assert "not available" in missing["error"].lower()


def test_session_usage_tool_is_registered_and_in_core_toolsets():
    from model_tools import _AGENT_LOOP_TOOLS, get_tool_definitions
    from toolsets import resolve_toolset
    from tools.registry import registry

    assert "session_usage" in registry.get_all_tool_names()
    assert "session_usage" in _AGENT_LOOP_TOOLS
    assert "session_usage" in resolve_toolset("session")
    assert "session_usage" in resolve_toolset("hermes-cli")
    assert "session_usage" in resolve_toolset("hermes-acp")
    assert "session_usage" in resolve_toolset("hermes-api-server")

    names = {
        definition["function"]["name"]
        for definition in get_tool_definitions(enabled_toolsets=["session"], quiet_mode=True)
    }
    assert names == {"session_search", "session_usage"}
