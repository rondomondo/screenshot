import pytest

from ssc import DEFAULT_LOG_LEVEL, resolve_log_level


def test_default_is_warning() -> None:
    assert resolve_log_level(None, {}) == DEFAULT_LOG_LEVEL == "WARNING"


def test_log_level_env_is_used_and_normalised() -> None:
    assert resolve_log_level(None, {"LOG_LEVEL": "info"}) == "INFO"
    assert resolve_log_level(None, {"LOG_LEVEL": "warn"}) == "WARNING"


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "on"])
def test_debug_truthy_values_enable_debug(value: str) -> None:
    """Regression: DEBUG had no effect on ssc.py logging."""
    assert resolve_log_level(None, {"DEBUG": value}) == "DEBUG"


@pytest.mark.parametrize("value", ["0", "", "false", "pw:mcp*"])
def test_debug_other_values_are_ignored(value: str) -> None:
    assert resolve_log_level(None, {"DEBUG": value}) == "WARNING"


def test_precedence_cli_over_env_over_debug() -> None:
    env = {"LOG_LEVEL": "ERROR", "DEBUG": "1"}
    assert resolve_log_level("info", env) == "INFO"
    assert resolve_log_level(None, env) == "ERROR"


def test_invalid_level_raises() -> None:
    with pytest.raises(ValueError, match="Invalid log level"):
        resolve_log_level("loud", {})
