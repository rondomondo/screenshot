import re

from ssc import AUTOCONSENT_AND_POPUP_DISMISSER_JS


def test_dismisser_never_forces_overflow_auto() -> None:
    """Regression: forcing overflow:auto on html/body clipped full-page captures at the viewport height."""
    assert not re.search(r"style\.overflow\s*=\s*['\"]auto['\"]", AUTOCONSENT_AND_POPUP_DISMISSER_JS)


def test_dismisser_only_unlocks_hidden_overflow() -> None:
    assert "overflowY === 'hidden'" in AUTOCONSENT_AND_POPUP_DISMISSER_JS


def test_dismisser_only_unfixes_fixed_body() -> None:
    assert "position === 'fixed'" in AUTOCONSENT_AND_POPUP_DISMISSER_JS


def test_unclip_ignores_small_and_hidden_scrollers() -> None:
    """Regression: hidden dropdown menus were freed and reflowed the whole page (Wikipedia)."""
    from ssc import UNCLIP_JS

    assert "cs.visibility === 'hidden'" in UNCLIP_JS
    assert "window.innerHeight * MIN_VIEWPORT_RATIO" in UNCLIP_JS


def test_unclip_is_applied_to_screenshots() -> None:
    import inspect

    from ssc import capture_screenshot

    assert "unclip_page(session)" in inspect.getsource(capture_screenshot)
