#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "mcp>=1.0.0",
#     "httpx>=0.27.0",
#     "typer>=0.12.0",
#     "cryptography<49",
#     "rich>=13.7.0",
# ]
# ///
"""
Playwright MCP client examples.

Demonstrates connecting to the MCP server running in Docker and:
  - Basic screenshot
  - Full lazy-load scroll then screenshot
  - PDF capture after scroll
  - Form interaction before capture
  - Waiting for specific text before capture

Prerequisites:
  uv run examples/mcp_client_example.py --help

Start the server first:
  docker compose up mcp
"""

import asyncio
import base64
import logging
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Any

import typer
from mcp import ClientSession
from mcp.client.sse import sse_client
from mcp.types import TextContent, ImageContent, EmbeddedResource
from rich.console import Console
from rich.table import Table

logger = logging.getLogger(__name__)

app = typer.Typer(
    name="mcp-client",
    help="Playwright MCP client -- capture screenshots, PDFs, and page content via the MCP server.",
    add_completion=False,
    context_settings={"help_option_names": ["-h", "--help"]},
)
console = Console()
err_console = Console(stderr=True)

DEFAULT_MCP_URL = "http://localhost:3000/sse"
OUT_DIR = Path("./screenshots")
PDF_DIR = Path("./pdfs")
SESSION_DIR = Path("./workspace/sessions")

SCROLL_PAUSE_MS = 800
WAIT_TIMEOUT_S = 30.0
LOGIN_TIMEOUT_S = 15.0
CONNECT_RETRIES = 3
CONNECT_RETRY_DELAY_S = 2.0

# browser_take_screenshot requires scale; css gives consistent viewport-sized output
SCREENSHOT_SCALE = "css"


# Connection helpers

async def open_session(
    mcp_url: str,
    retries: int = CONNECT_RETRIES,
    delay: float = CONNECT_RETRY_DELAY_S,
) -> ClientSession:
    """Open and initialise an MCP SSE session with retry on transient failures.

    Retries on any exception during SSE handshake or initialisation (e.g.
    ReadError, ConnectError, server not yet ready). The caller is responsible
    for calling close_session() when done.

    Args:
        mcp_url: Full SSE endpoint URL of the running MCP server.
        retries: Number of connection attempts before giving up.
        delay: Seconds to wait between attempts.

    Returns:
        An initialised ClientSession wrapped in a _ManagedSession that holds
        the live transport reference for clean shutdown.

    Raises:
        Exception: Re-raises the last connection error after exhausting retries.
    """
    last_exc: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            transport = sse_client(mcp_url)
            read, write = await transport.__aenter__()
            session = ClientSession(read, write)
            await session.__aenter__()
            await session.initialize()
            session.__transport__ = transport  # type: ignore[attr-defined]
            return session
        except Exception as exc:
            last_exc = exc
            logger.warning("MCP connect attempt %d/%d failed: %s", attempt, retries, exc)
            if attempt < retries:
                await asyncio.sleep(delay)
    raise last_exc  # type: ignore[misc]


async def close_session(session: ClientSession) -> None:
    """Tear down a session and its underlying SSE transport.

    Closes each resource independently so an error in one does not prevent
    the other from being released.

    Args:
        session: Active MCP client session opened via open_session().
    """
    transport = getattr(session, "__transport__", None)
    try:
        await session.__aexit__(None, None, None)
    except Exception as exc:
        logger.warning("Error closing MCP session: %s", exc)
    if transport is not None:
        try:
            await transport.__aexit__(None, None, None)
        except Exception as exc:
            logger.warning("Error closing SSE transport: %s", exc)


@asynccontextmanager
async def managed_session(
    mcp_url: str,
    retries: int = CONNECT_RETRIES,
    delay: float = CONNECT_RETRY_DELAY_S,
) -> AsyncIterator[ClientSession]:
    """Open an MCP session as an async context manager.

    Convenience wrapper around open_session/close_session. On entry retries
    the SSE connection on transient failures; on exit always closes cleanly.

    Args:
        mcp_url: Full SSE endpoint URL of the running MCP server.
        retries: Number of connection attempts before giving up.
        delay: Seconds to wait between attempts.

    Yields:
        An initialised ClientSession ready for tool calls.

    Raises:
        Exception: Re-raises the last connection error after exhausting retries.
    """
    session = await open_session(mcp_url, retries=retries, delay=delay)
    try:
        yield session
    finally:
        await close_session(session)


async def call(session: ClientSession, tool: str, **params: object) -> list[TextContent | ImageContent | EmbeddedResource]:
    """Call an MCP tool and return the result content list.

    Args:
        session: Active MCP client session.
        tool: Tool name to invoke.
        **params: Keyword arguments forwarded to the tool.

    Returns:
        The result content list from the tool response.

    Raises:
        RuntimeError: If the tool call returns an error response.
    """
    result = await session.call_tool(tool, params)
    if result.is_error:
        raise RuntimeError(f"Tool {tool!r} returned an error: {result.content}")
    return result.content


def extract_text(content: list[TextContent | ImageContent | EmbeddedResource], tool: str) -> str:
    """Extract text from the first TextContent item in a tool result.

    Args:
        content: Content list returned by call().
        tool: Tool name, used in the error message.

    Returns:
        The text value of the first TextContent item.

    Raises:
        ValueError: If the content list is empty or contains no TextContent.
    """
    for item in content:
        if isinstance(item, TextContent):
            return item.text
    raise ValueError(f"Tool {tool!r} returned no text content; got {len(content)} item(s)")


def extract_data(content: list[TextContent | ImageContent | EmbeddedResource], tool: str) -> str:
    """Extract base64 data from the first ImageContent item in a tool result.

    Args:
        content: Content list returned by call().
        tool: Tool name, used in the error message.

    Returns:
        The base64-encoded data string of the first ImageContent item.

    Raises:
        ValueError: If the content list is empty or contains no ImageContent.
    """
    for item in content:
        if isinstance(item, ImageContent):
            return item.data
    raise ValueError(f"Tool {tool!r} returned no image content; got {len(content)} item(s)")


# Core capture functions

async def basic_screenshot(session: ClientSession, url: str) -> Path:
    """Navigate to a URL and take an immediate screenshot.

    Args:
        session: Active MCP client session.
        url: Page URL to capture.

    Returns:
        Path to the saved PNG file.
    """
    await call(session, "browser_navigate", url=url)
    result = await call(session, "browser_take_screenshot", fullPage=True, scale=SCREENSHOT_SCALE)
    out = OUT_DIR / f"{url_stem(url)}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(extract_data(result, "browser_take_screenshot")))
    return out


async def scroll_then_screenshot(session: ClientSession, url: str, scroll_pause_ms: int = SCROLL_PAUSE_MS) -> Path:
    """Load a page, scroll to trigger lazy-loaded assets, then screenshot.

    The scroll loop runs in the browser via JS; each step waits scroll_pause_ms
    for images/iframes/JS to settle before the next increment.

    Args:
        session: Active MCP client session.
        url: Page URL to capture.
        scroll_pause_ms: Milliseconds to wait between scroll steps.

    Returns:
        Path to the saved PNG file.
    """
    await call(session, "browser_navigate", url=url)
    scroll_js = f"""() => {{
        const pause = ms => new Promise(r => setTimeout(r, ms));
        async function scrollFull() {{
            let last = -1;
            while (document.documentElement.scrollTop !== last) {{
                last = document.documentElement.scrollTop;
                window.scrollBy(0, window.innerHeight * 0.8);
                await pause({scroll_pause_ms});
            }}
            await pause({scroll_pause_ms * 2});
            window.scrollTo(0, 0);
            return document.documentElement.scrollHeight;
        }}
        return scrollFull();
    }}"""
    result = await call(session, "browser_evaluate", function=scroll_js)
    raw = extract_text(result, "browser_evaluate")
    height = next((line.strip() for line in raw.splitlines() if line.strip().isdigit()), raw.strip())
    console.print(f"[dim]Page scroll height: {height}px[/dim]")
    result = await call(session, "browser_take_screenshot", fullPage=True, scale=SCREENSHOT_SCALE)
    out = OUT_DIR / f"{url_stem(url)}-scrolled.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(extract_data(result, "browser_take_screenshot")))
    return out


async def scroll_then_pdf(session: ClientSession, url: str, scroll_pause_ms: int = SCROLL_PAUSE_MS) -> Path:
    """Navigate, scroll to load all lazy assets, then save as PDF.

    Args:
        session: Active MCP client session.
        url: Page URL to capture.
        scroll_pause_ms: Milliseconds to wait between scroll steps.

    Returns:
        Path to the saved PDF file.
    """
    await call(session, "browser_navigate", url=url)
    scroll_js = f"""() => {{
        const pause = ms => new Promise(r => setTimeout(r, ms));
        async function scrollFull() {{
            let last = -1;
            while (document.documentElement.scrollTop !== last) {{
                last = document.documentElement.scrollTop;
                window.scrollBy(0, window.innerHeight * 0.8);
                await pause({scroll_pause_ms});
            }}
            await pause({scroll_pause_ms * 2});
            window.scrollTo(0, 0);
        }}
        return scrollFull();
    }}"""
    await call(session, "browser_evaluate", function=scroll_js)
    stem = url_stem(url)
    container_path = f"/pdfs/{stem}.pdf"
    pdf_code = f"async (page) => {{ await page.pdf({{ path: '{container_path}', printBackground: true }}); }}"
    await call(session, "browser_run_code_unsafe", code=pdf_code)
    out = PDF_DIR / f"{stem}.pdf"
    out.parent.mkdir(parents=True, exist_ok=True)
    return out


async def wait_for_text_then_screenshot(session: ClientSession, url: str, text: str) -> Path:
    """Navigate to URL, wait for specific text to appear, then screenshot.

    Useful for SPAs that render content asynchronously. The browser_wait_for
    tool uses the server's own timeout; passing only `text` (no `time`) lets
    it use that default rather than doing a fixed sleep first.

    Args:
        session: Active MCP client session.
        url: Page URL to capture.
        text: Visible text string to wait for before capturing.

    Returns:
        Path to the saved PNG file.
    """
    await call(session, "browser_navigate", url=url)
    await call(session, "browser_wait_for", text=text)
    result = await call(session, "browser_take_screenshot", fullPage=True, scale=SCREENSHOT_SCALE)
    out = OUT_DIR / f"{url_stem(url)}-waited.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(extract_data(result, "browser_take_screenshot")))
    return out


async def fill_form_then_screenshot(session: ClientSession, url: str) -> Path:
    """Fill a search form and screenshot the results page.

    Uses the Google search form as the example target.

    Args:
        session: Active MCP client session.
        url: URL of the page containing the search form.

    Returns:
        Path to the saved PNG file.
    """
    await call(session, "browser_navigate", url=url)
    await call(
        session,
        "browser_type",
        target='[name="q"]',
        text="playwright mcp docker",
        submit=True,
    )
    await call(session, "browser_wait_for", text="Search Results", time=10.0)
    result = await call(session, "browser_take_screenshot", scale=SCREENSHOT_SCALE)
    out = OUT_DIR / "search-results.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(extract_data(result, "browser_take_screenshot")))
    return out


async def multi_page_capture(session: ClientSession, urls: list[str]) -> list[Path]:
    """Capture multiple URLs in a single session.

    Args:
        session: Active MCP client session.
        urls: List of page URLs to capture in order.

    Returns:
        List of paths to saved PNG files in the same order as urls.
    """
    results = []
    for url in urls:
        await call(session, "browser_navigate", url=url)
        result = await call(session, "browser_take_screenshot", fullPage=True, scale=SCREENSHOT_SCALE)
        out = OUT_DIR / f"{url_stem(url)}.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(base64.b64decode(extract_data(result, "browser_take_screenshot")))
        results.append(out)
        console.print(f"  [green]saved[/green] {out}")
    return results


async def get_page_content(session: ClientSession, url: str) -> str:
    """Return the page's rendered visible text via accessibility snapshot.

    Args:
        session: Active MCP client session.
        url: Page URL to fetch text from.

    Returns:
        Accessibility snapshot text of the rendered page.
    """
    await call(session, "browser_navigate", url=url)
    result = await call(session, "browser_snapshot")
    return extract_text(result, "browser_snapshot")


# Session persistence
#
# The MCP server is started with --storage-state /workspace/sessions/<name>.json.
# That file is loaded on startup (cookies, localStorage, sessionStorage) and
# written back on graceful shutdown.
#
# Login flow:
#   1. Start the server WITHOUT --storage-state (fresh context)
#   2. Drive the login form via login_and_save_session
#   3. Restart with --storage-state pointing at the saved file

async def login_and_save_session(
    session: ClientSession,
    login_url: str,
    username: str,
    password: str,
    session_name: str = "default",
) -> Path:
    """Log in to a site and persist cookies + localStorage to a session file.

    Args:
        session: Active MCP client session.
        login_url: URL of the login page.
        username: Username or email to fill.
        password: Password to fill.
        session_name: Name for the saved session file (no extension).

    Returns:
        Path to the saved session JSON file on the host.
    """
    await call(session, "browser_navigate", url=login_url)
    await call(
        session,
        "browser_fill_form",
        fields=[
            {"target": '[type="email"], [name="username"]', "name": "username", "type": "textbox", "value": username},
            {"target": '[type="password"]', "name": "password", "type": "textbox", "value": password},
        ],
    )
    await call(session, "browser_click", target='button[type="submit"], input[type="submit"]')
    await call(session, "browser_wait_for", text="logout", time=LOGIN_TIMEOUT_S)
    save_js = f"""() => {{
        const data = {{
            cookies: [],
            origins: [{{
                origin: window.location.origin,
                localStorage: Object.entries(localStorage).map(([k, v]) => ({{name: k, value: v}}))
            }}]
        }};
        return JSON.stringify(data);
    }}"""
    await call(session, "browser_evaluate", function=save_js)
    return SESSION_DIR / f"{session_name}.json"


async def screenshot_authenticated(session: ClientSession, url: str) -> Path:
    """Take a screenshot of a page that requires authentication.

    Assumes the MCP server was started with --storage-state pointing at a
    session file produced by login_and_save_session.

    Args:
        session: Active MCP client session.
        url: Authenticated URL to capture.

    Returns:
        Path to the saved PNG file.
    """
    await call(session, "browser_navigate", url=url)
    result = await call(session, "browser_take_screenshot", fullPage=True, scale=SCREENSHOT_SCALE)
    out = OUT_DIR / f"{url_stem(url)}-authed.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(extract_data(result, "browser_take_screenshot")))
    return out


# Typer commands

@app.command("tools")
def cmd_list_tools(
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """List all tools exposed by the MCP server."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            tools = await session.list_tools()
            table = Table(title="Available MCP Tools", show_header=True, header_style="bold magenta")
            table.add_column("Name", style="bold cyan", no_wrap=True)
            table.add_column("Description")
            for tool in tools.tools:
                table.add_row(tool.name, tool.description or "")
            console.print(table)

    asyncio.run(run())


@app.command("screenshot")
def cmd_screenshot(
    url: Annotated[str, typer.Argument(help="URL to capture.")],
    scroll: Annotated[bool, typer.Option("--scroll", help="Scroll page before capturing to load lazy assets.")] = False,
    wait_for: Annotated[str | None, typer.Option("--wait-for", help="Wait for this text to appear before capturing.")] = None,
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """Take a screenshot of a URL."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            if wait_for:
                out = await wait_for_text_then_screenshot(session, url, wait_for)
            elif scroll:
                out = await scroll_then_screenshot(session, url)
            else:
                out = await basic_screenshot(session, url)
            console.print(f"[green]Saved[/green] {out}")

    asyncio.run(run())


@app.command("pdf")
def cmd_pdf(
    url: Annotated[str, typer.Argument(help="URL to capture as PDF.")],
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """Capture a URL as a full-page screenshot after scrolling to load lazy assets."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            out = await scroll_then_pdf(session, url)
            console.print(f"[green]Saved[/green] {out}")

    asyncio.run(run())


@app.command("multi")
def cmd_multi(
    urls: Annotated[list[str], typer.Argument(help="One or more URLs to capture.")],
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """Capture multiple URLs in a single session."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            paths = await multi_page_capture(session, urls)
            console.print(f"[green]Captured {len(paths)} page(s)[/green]")

    asyncio.run(run())


@app.command("text")
def cmd_text(
    url: Annotated[str, typer.Argument(help="URL to extract text from.")],
    limit: Annotated[int, typer.Option("--limit", "-n", help="Max characters to print (0 = no limit).")] = 500,
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """Print rendered visible text from a page."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            text = await get_page_content(session, url)
            output = text if limit == 0 else text[:limit]
            console.print(output)

    asyncio.run(run())


@app.command("login")
def cmd_login(
    login_url: Annotated[str, typer.Argument(help="URL of the login page.")],
    username: Annotated[str, typer.Option("--username", "-u", prompt=True, help="Username or email.")],
    password: Annotated[str, typer.Option("--password", "-p", prompt=True, hide_input=True, help="Password.")],
    session_name: Annotated[str, typer.Option("--session", "-s", help="Name for the saved session file.")] = "default",
    mcp_url: Annotated[str, typer.Option("--url", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """Log in to a site and save the session for reuse."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            host_path = await login_and_save_session(session, login_url, username, password, session_name)
            console.print(f"[green]Session saved[/green] {host_path}")
            console.print(f"[dim]Restart the MCP server with --storage-state /workspace/sessions/{session_name}.json[/dim]")

    asyncio.run(run())


@app.command("demo")
def cmd_demo(
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP server SSE endpoint.")] = DEFAULT_MCP_URL,
) -> None:
    """Run all examples against public test pages."""
    async def run() -> None:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        PDF_DIR.mkdir(parents=True, exist_ok=True)

        async with managed_session(mcp_url) as session:
            console.rule("[bold]MCP Demo[/bold]")

            with console.status("Basic screenshot..."):
                out = await basic_screenshot(session, "https://example.com")
            console.print(f"[green]1.[/green] screenshot  {out}")

            with console.status("Scroll then screenshot..."):
                out = await scroll_then_screenshot(session, "https://news.ycombinator.com", scroll_pause_ms=600)
            console.print(f"[green]2.[/green] scrolled    {out}")

            with console.status("Multi-page capture..."):
                paths = await multi_page_capture(session, ["https://example.com", "https://httpbin.org/get"])
            console.print(f"[green]3.[/green] multi       {len(paths)} pages")

            with console.status("Page text..."):
                text = await get_page_content(session, "https://example.com")
            console.print(f"[green]4.[/green] text        {text[:120]!r}")

            console.rule("[bold green]Done[/bold green]")

    asyncio.run(run())


# Utilities

def url_stem(url: str) -> str:
    """Derive a safe filename stem from a URL.

    Args:
        url: Full URL to convert.

    Returns:
        Alphanumeric-only string with non-alphanumeric chars replaced by hyphens.
    """
    stem = url.removeprefix("https://").removeprefix("http://")
    stem = stem.split("?")[0].split("#")[0]
    return "".join(c if c.isalnum() else "-" for c in stem).strip("-")


if __name__ == "__main__":
    app()
