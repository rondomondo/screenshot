"""Tests for mcp_client_example.

All tests use a mock ClientSession so no live MCP server is required.
The session fixture is injected into each test via pytest-asyncio's async
fixture support.

Coverage:
  - url_stem: pure function, covers edge cases
  - extract_text / extract_data: content extraction helpers
  - call: error propagation from is_error responses
  - basic_screenshot: navigate + screenshot + file write
  - scroll_then_screenshot: navigate + evaluate + screenshot
  - scroll_then_pdf: navigate + evaluate + browser_run_code_unsafe page.pdf() (saves as .pdf)
  - wait_for_text_then_screenshot: navigate + wait_for + screenshot
  - fill_form_then_screenshot: navigate + type + wait + screenshot
  - multi_page_capture: multiple navigations + screenshots
  - get_page_content: navigate + snapshot
  - login_and_save_session: full login flow
  - screenshot_authenticated: navigate + screenshot
  - open_session / close_session: connection lifecycle
  - managed_session: context manager teardown on success and on exception,
    retry on transient failures
"""

import base64
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest
from mcp.types import CallToolResult, ImageContent, TextContent

import mcp_client_example as mod


# Helpers

def make_text(text: str) -> list[TextContent]:
    return [TextContent(type="text", text=text)]


def make_image(data: bytes) -> list[ImageContent]:
    return [ImageContent(type="image", data=base64.b64encode(data).decode(), mimeType="image/png")]


def ok_result(content: list) -> CallToolResult:
    return CallToolResult(content=content, isError=False)


def err_result(msg: str) -> CallToolResult:
    return CallToolResult(content=make_text(msg), isError=True)


def make_session(side_effects: list[CallToolResult]) -> AsyncMock:
    session = AsyncMock()
    session.call_tool = AsyncMock(side_effect=side_effects)
    return session


# url_stem


def test_url_stem_https() -> None:
    assert mod.url_stem("https://example.com/path/to/page") == "example-com-path-to-page"


def test_url_stem_http() -> None:
    assert mod.url_stem("http://foo.bar") == "foo-bar"


def test_url_stem_strips_query_and_fragment() -> None:
    assert mod.url_stem("https://example.com/page?foo=bar#section") == "example-com-page"


def test_url_stem_trailing_slashes() -> None:
    result = mod.url_stem("https://example.com/")
    assert not result.endswith("-")


def test_url_stem_no_special_chars() -> None:
    stem = mod.url_stem("https://example.com/hello-world")
    assert all(c.isalnum() or c == "-" for c in stem)


# extract_text


def test_extract_text_returns_first_text_content() -> None:
    content = make_text("hello")
    assert mod.extract_text(content, "tool") == "hello"


def test_extract_text_skips_image_content() -> None:
    img = ImageContent(type="image", data="abc", mimeType="image/png")
    txt = TextContent(type="text", text="found")
    assert mod.extract_text([img, txt], "tool") == "found"


def test_extract_text_raises_on_empty() -> None:
    with pytest.raises(ValueError, match="no text content"):
        mod.extract_text([], "mytool")


def test_extract_text_raises_when_only_image() -> None:
    img = ImageContent(type="image", data="abc", mimeType="image/png")
    with pytest.raises(ValueError, match="no text content"):
        mod.extract_text([img], "mytool")


# extract_data


def test_extract_data_returns_first_image_content() -> None:
    content = make_image(b"pngdata")
    assert mod.extract_data(content, "tool") == base64.b64encode(b"pngdata").decode()


def test_extract_data_skips_text_content() -> None:
    txt = TextContent(type="text", text="ignore")
    img = ImageContent(type="image", data="abc123", mimeType="image/png")
    assert mod.extract_data([txt, img], "tool") == "abc123"


def test_extract_data_raises_on_empty() -> None:
    with pytest.raises(ValueError, match="no image content"):
        mod.extract_data([], "mytool")


def test_extract_data_raises_when_only_text() -> None:
    with pytest.raises(ValueError, match="no image content"):
        mod.extract_data(make_text("hello"), "mytool")


# call


@pytest.mark.asyncio
async def test_call_returns_content_on_success() -> None:
    session = AsyncMock()
    session.call_tool = AsyncMock(return_value=ok_result(make_text("done")))
    result = await mod.call(session, "some_tool", url="https://example.com")
    session.call_tool.assert_called_once_with("some_tool", {"url": "https://example.com"})
    assert result[0].text == "done"  # type: ignore[union-attr]


@pytest.mark.asyncio
async def test_call_raises_on_error_result() -> None:
    session = AsyncMock()
    session.call_tool = AsyncMock(return_value=err_result("something went wrong"))
    with pytest.raises(RuntimeError, match="returned an error"):
        await mod.call(session, "bad_tool")


# basic_screenshot


@pytest.mark.asyncio
async def test_basic_screenshot(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    png = b"PNGDATA"
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_image(png)),
    ])
    out = await mod.basic_screenshot(session, "https://example.com")
    assert out.exists()
    assert out.read_bytes() == png
    assert session.call_tool.call_count == 2


# scroll_then_screenshot


@pytest.mark.asyncio
async def test_scroll_then_screenshot(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    png = b"SCROLLPNG"
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_text("### Result\n1200\n### Ran Playwright code")),
        ok_result(make_image(png)),
    ])
    out = await mod.scroll_then_screenshot(session, "https://example.com")
    assert out.exists()
    assert out.read_bytes() == png
    assert out.name.endswith("-scrolled.png")


# scroll_then_pdf


@pytest.mark.asyncio
async def test_scroll_then_pdf(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "PDF_DIR", tmp_path)
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_text("")),
        ok_result(make_text("")),
    ])
    out = await mod.scroll_then_pdf(session, "https://example.com")
    assert out.suffix == ".pdf"
    calls = session.call_tool.call_args_list
    assert calls[2][0][0] == "browser_run_code_unsafe"
    assert "page.pdf" in calls[2][0][1]["code"]
    assert "example-com" in calls[2][0][1]["code"]


# wait_for_text_then_screenshot


@pytest.mark.asyncio
async def test_wait_for_text_then_screenshot(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    png = b"WAITPNG"
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_text("found")),
        ok_result(make_image(png)),
    ])
    out = await mod.wait_for_text_then_screenshot(session, "https://example.com", "Example Domain")
    assert out.exists()
    assert out.read_bytes() == png
    assert out.name.endswith("-waited.png")
    calls = session.call_tool.call_args_list
    assert calls[1] == call("browser_wait_for", {"text": "Example Domain"})


# fill_form_then_screenshot


@pytest.mark.asyncio
async def test_fill_form_then_screenshot(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    png = b"FORMPNG"
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_text("typed")),
        ok_result(make_text("found")),
        ok_result(make_image(png)),
    ])
    out = await mod.fill_form_then_screenshot(session, "https://google.com")
    assert out.exists()
    assert out.read_bytes() == png
    assert out.name == "search-results.png"


# multi_page_capture


@pytest.mark.asyncio
async def test_multi_page_capture(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    urls = ["https://example.com", "https://httpbin.org/get"]
    png = b"MULTIPNG"
    session = make_session([
        ok_result(make_text("nav1")),
        ok_result(make_image(png)),
        ok_result(make_text("nav2")),
        ok_result(make_image(png)),
    ])
    paths = await mod.multi_page_capture(session, urls)
    assert len(paths) == 2
    for p in paths:
        assert p.exists()
        assert p.read_bytes() == png


# get_page_content (now uses browser_snapshot)


@pytest.mark.asyncio
async def test_get_page_content(monkeypatch: pytest.MonkeyPatch) -> None:
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_text("Hello World")),
    ])
    text = await mod.get_page_content(session, "https://example.com")
    assert text == "Hello World"
    calls = session.call_tool.call_args_list
    assert calls[1][0][0] == "browser_snapshot"


# login_and_save_session


@pytest.mark.asyncio
async def test_login_and_save_session(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "SESSION_DIR", Path("/tmp/sessions"))
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_text("filled form")),
        ok_result(make_text("clicked")),
        ok_result(make_text("found logout")),
        ok_result(make_text("{}")),
    ])
    host_path = await mod.login_and_save_session(
        session, "https://app.example.com/login", "user@example.com", "secret", "myapp"
    )
    assert host_path == Path("/tmp/sessions/myapp.json")


# screenshot_authenticated


@pytest.mark.asyncio
async def test_screenshot_authenticated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    png = b"AUTHPNG"
    session = make_session([
        ok_result(make_text("navigated")),
        ok_result(make_image(png)),
    ])
    out = await mod.screenshot_authenticated(session, "https://app.example.com/dashboard")
    assert out.exists()
    assert out.read_bytes() == png
    assert out.name.endswith("-authed.png")


# open_session / close_session


@pytest.mark.asyncio
async def test_open_session_succeeds_on_first_attempt() -> None:
    mock_session = AsyncMock()

    mock_transport = MagicMock()
    mock_transport.__aenter__ = AsyncMock(return_value=(AsyncMock(), AsyncMock()))

    mock_cs_instance = AsyncMock()
    mock_cs_instance.__aenter__ = AsyncMock(return_value=mock_session)

    with (
        patch.object(mod, "sse_client", return_value=mock_transport),
        patch.object(mod, "ClientSession", return_value=mock_cs_instance),
    ):
        session = await mod.open_session("http://localhost:3000/sse", retries=3, delay=0.0)

    assert session is mock_cs_instance
    mock_cs_instance.initialize.assert_called_once()


@pytest.mark.asyncio
async def test_open_session_retries_on_failure() -> None:
    mock_session = AsyncMock()
    call_count = 0

    def make_transport(url: str) -> MagicMock:
        nonlocal call_count
        call_count += 1
        t = MagicMock()
        if call_count < 3:
            t.__aenter__ = AsyncMock(side_effect=ConnectionError("not ready yet"))
        else:
            t.__aenter__ = AsyncMock(return_value=(AsyncMock(), AsyncMock()))
        return t

    mock_cs_instance = AsyncMock()
    mock_cs_instance.__aenter__ = AsyncMock(return_value=mock_session)

    with (
        patch.object(mod, "sse_client", side_effect=make_transport),
        patch.object(mod, "ClientSession", return_value=mock_cs_instance),
        patch("asyncio.sleep", new_callable=AsyncMock),
    ):
        session = await mod.open_session("http://localhost:3000/sse", retries=3, delay=0.0)

    assert call_count == 3
    assert session is mock_cs_instance


@pytest.mark.asyncio
async def test_open_session_raises_after_exhaustion() -> None:
    with (
        patch.object(mod, "sse_client") as mock_sse,
        patch("asyncio.sleep", new_callable=AsyncMock),
    ):
        mock_transport = MagicMock()
        mock_transport.__aenter__ = AsyncMock(side_effect=ConnectionError("refused"))
        mock_sse.return_value = mock_transport

        with pytest.raises(ConnectionError, match="refused"):
            await mod.open_session("http://localhost:3000/sse", retries=2, delay=0.0)


@pytest.mark.asyncio
async def test_close_session_closes_transport() -> None:
    transport = AsyncMock()
    session = AsyncMock()
    session.__transport__ = transport
    await mod.close_session(session)
    session.__aexit__.assert_called_once_with(None, None, None)
    transport.__aexit__.assert_called_once_with(None, None, None)


@pytest.mark.asyncio
async def test_close_session_closes_transport_even_if_session_raises() -> None:
    transport = AsyncMock()
    session = AsyncMock()
    session.__aexit__ = AsyncMock(side_effect=RuntimeError("session error"))
    session.__transport__ = transport
    await mod.close_session(session)
    transport.__aexit__.assert_called_once_with(None, None, None)


# managed_session


def _make_open_session_mock(mock_session: AsyncMock) -> AsyncMock:
    mock_session.__transport__ = AsyncMock()
    mock_session.__transport__.__aexit__ = AsyncMock(return_value=False)
    mock_session.__aexit__ = AsyncMock(return_value=False)
    return mock_session


@pytest.mark.asyncio
async def test_managed_session_yields_initialised_session() -> None:
    mock_session = _make_open_session_mock(AsyncMock())

    with patch.object(mod, "open_session", return_value=mock_session) as mock_open:
        async with mod.managed_session("http://localhost:3000/sse", retries=1) as session:
            assert session is mock_session

    mock_open.assert_called_once_with("http://localhost:3000/sse", retries=1, delay=mod.CONNECT_RETRY_DELAY_S)


@pytest.mark.asyncio
async def test_managed_session_closes_on_exception() -> None:
    mock_session = _make_open_session_mock(AsyncMock())

    with patch.object(mod, "open_session", return_value=mock_session):
        with pytest.raises(RuntimeError, match="boom"):
            async with mod.managed_session("http://localhost:3000/sse", retries=1):
                raise RuntimeError("boom")

    mock_session.__aexit__.assert_called_once()


@pytest.mark.asyncio
async def test_managed_session_retries_on_read_error() -> None:
    mock_session = _make_open_session_mock(AsyncMock())
    call_count = 0

    async def flaky_open(url: str, retries: int, delay: float) -> AsyncMock:
        nonlocal call_count
        call_count += 1
        if call_count < 2:
            raise ConnectionError("ReadError")
        return mock_session

    with patch.object(mod, "open_session", side_effect=flaky_open):
        with pytest.raises(ConnectionError):
            async with mod.managed_session("http://localhost:3000/sse", retries=1):
                pass


@pytest.mark.asyncio
async def test_managed_session_raises_after_exhausted_retries() -> None:
    with patch.object(mod, "open_session", side_effect=ConnectionError("refused")):
        with pytest.raises(ConnectionError, match="refused"):
            async with mod.managed_session("http://localhost:3000/sse", retries=1):
                pass
