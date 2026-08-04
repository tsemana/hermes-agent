"""Tests for the sticky "answering on a fallback model" notice.

A fallback that SUCCEEDS is a persistent state change, not transient retry
noise: every following turn is answered by a different model until the primary
recovers.  The "switching to fallback" line goes through ``_buffer_status``,
which is dropped on success by design (see the buffered-status contract in
run_agent.py), and ``_emit_status`` renders transiently in the GUI drivers —
so before this notice the only durable trace was agent.log, and a session could
run on the local fallback with the user reading answers as if they came from
the configured primary.

Guards both halves of the pairing:
  * try_activate_fallback  -> fires a sticky AgentNotice
  * restore_primary_runtime -> clears it by the same key
"""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from agent.chat_completion_helpers import MODEL_FALLBACK_NOTICE_KEY


def _make_agent(provider="custom:vibeproxy", model="gpt-5.6-sol",
                base_url="http://127.0.0.1:8317/v1",
                api_mode="chat_completions"):
    """Minimal AIAgent-like stub for the activation path."""
    agent = MagicMock()
    agent.provider = provider
    agent.model = model
    agent.base_url = base_url
    agent.api_mode = api_mode
    agent.api_key = "primary-key"
    agent._fallback_activated = False
    agent._fallback_index = 0
    agent._fallback_chain = []
    agent._config_context_length = None
    agent._credential_pool = None
    agent._rate_limited_until = 0
    agent._transport_cache = {}
    agent._client_kwargs = {"api_key": "primary-key", "base_url": base_url}
    agent._primary_runtime = {
        "provider": provider,
        "model": model,
        "base_url": base_url,
        "api_mode": api_mode,
        "api_key": "primary-key",
        "client_kwargs": {"api_key": "primary-key", "base_url": base_url},
        "use_prompt_caching": False,
        "use_native_cache_layout": False,
        "anthropic_api_key": "",
        "anthropic_base_url": "",
    }
    agent._is_azure_openai_url.return_value = False
    agent._is_direct_openai_url.return_value = False
    agent._provider_model_requires_responses_api.return_value = False
    agent._anthropic_prompt_cache_policy.return_value = (False, False)
    agent._ensure_lmstudio_runtime_loaded = MagicMock()
    agent._replace_primary_openai_client = MagicMock()
    agent.context_compressor = None
    return agent


def _activate(agent):
    """Run the real activator against a stubbed local-MLX fallback entry."""
    from agent.chat_completion_helpers import try_activate_fallback

    fallback_client = SimpleNamespace(
        api_key="local-key",
        base_url="http://127.0.0.1:4321/v1",
        _custom_headers={},
    )
    with patch(
        "agent.auxiliary_client.resolve_provider_client",
        return_value=(fallback_client, "Qwen3.6-35B-A3B-nvfp4"),
    ), patch("agent.credential_pool.load_pool", return_value=None):
        return try_activate_fallback(agent)


class TestFallbackNoticeEmitted:
    def test_successful_activation_fires_sticky_notice(self):
        agent = _make_agent()
        agent._fallback_chain = [{
            "provider": "custom:local-mlx",
            "model": "Qwen3.6-35B-A3B-nvfp4",
            "base_url": "http://127.0.0.1:4321/v1",
        }]

        assert _activate(agent) is True

        agent._emit_notice.assert_called_once()
        notice = agent._emit_notice.call_args[0][0]
        assert notice.key == MODEL_FALLBACK_NOTICE_KEY
        assert notice.kind == "sticky"
        assert notice.level == "warn"
        # Must name the model actually answering, and the primary it replaced,
        # or the user can't tell what degraded.
        assert "Qwen3.6-35B-A3B-nvfp4" in notice.text
        assert "gpt-5.6-sol" in notice.text

    def test_notice_survives_the_dropped_status_buffer(self):
        """The buffered status is discarded on success; the notice is not."""
        agent = _make_agent()
        agent._fallback_chain = [{
            "provider": "custom:local-mlx",
            "model": "Qwen3.6-35B-A3B-nvfp4",
            "base_url": "http://127.0.0.1:4321/v1",
        }]

        assert _activate(agent) is True

        # _buffer_status is the channel that gets dropped on recovery — the
        # notice must NOT be routed through it.
        assert agent._emit_notice.called
        buffered = [c[0][0] for c in agent._buffer_status.call_args_list]
        assert not any(MODEL_FALLBACK_NOTICE_KEY in str(b) for b in buffered)

    def test_no_notice_when_chain_is_empty(self):
        """Nothing to fall back to → no activation, so no notice."""
        agent = _make_agent()
        agent._fallback_chain = []

        from agent.chat_completion_helpers import try_activate_fallback

        assert try_activate_fallback(agent) is False
        agent._emit_notice.assert_not_called()

    def test_notice_failure_does_not_break_fallback(self):
        """Fail-open: a broken notice channel must not block the switch."""
        agent = _make_agent()
        agent._fallback_chain = [{
            "provider": "custom:local-mlx",
            "model": "Qwen3.6-35B-A3B-nvfp4",
            "base_url": "http://127.0.0.1:4321/v1",
        }]
        agent._emit_notice.side_effect = RuntimeError("driver gone")

        assert _activate(agent) is True
        assert agent.model == "Qwen3.6-35B-A3B-nvfp4"


class TestFallbackNoticeCleared:
    def test_restore_clears_the_notice(self):
        from agent.agent_runtime_helpers import restore_primary_runtime

        agent = _make_agent()
        agent._fallback_activated = True
        agent._rate_limited_until = 0
        agent._primary_runtime.update({
            "credential_pool": None,
            "compressor_model": "gpt-5.6-sol",
            "compressor_context_length": 258400,
            "compressor_base_url": "http://127.0.0.1:8317/v1",
            "compressor_api_key": "primary-key",
            "compressor_provider": "custom:vibeproxy",
            "compressor_api_mode": "chat_completions",
        })
        agent.context_compressor = MagicMock()

        assert restore_primary_runtime(agent) is True
        agent._emit_notice_clear.assert_called_once_with(MODEL_FALLBACK_NOTICE_KEY)

    def test_notice_persists_while_primary_is_still_cooling_down(self):
        """Still degraded → the notice must NOT be cleared."""
        import time

        from agent.agent_runtime_helpers import restore_primary_runtime

        agent = _make_agent()
        agent._fallback_activated = True
        agent._rate_limited_until = time.monotonic() + 60

        assert restore_primary_runtime(agent) is False
        agent._emit_notice_clear.assert_not_called()
