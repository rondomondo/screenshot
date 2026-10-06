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
"""Production-grade Playwright MCP client for automated captures and rendering."""

import asyncio
import base64
import json
import logging
import os
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Any

import typer
from mcp import ClientSession
from mcp.client.sse import sse_client
from mcp.types import EmbeddedResource, ImageContent, TextContent
from rich.console import Console
from rich.table import Table

# Setup structured logging
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("mcp_client")

app = typer.Typer(
    name="mcp-client",
    help="Playwright MCP Client -- Production toolkit for capture and automation.",
    add_completion=False,
    context_settings={"help_option_names": ["-h", "--help"]},
)
console = Console()
err_console = Console(stderr=True)

DEFAULT_MCP_URL = os.getenv("MCP_SERVER_URL", "http://localhost:3000/sse")
CONTAINER_SCREENSHOT_DIR = Path("/screenshots")
DEFAULT_OUT_DIR = Path(os.getenv("OUTPUT_DIR", "./screenshots"))
CONTAINER_PDF_DIR = Path("/pdfs")
DEFAULT_PDF_DIR = Path(os.getenv("PDF_OUTPUT_DIR", "./pdfs"))

CONNECT_RETRIES = 5
CONNECT_RETRY_DELAY_S = 2.0


# Connection Lifecycle Management

async def open_session(
    mcp_url: str,
    retries: int = CONNECT_RETRIES,
    delay: float = CONNECT_RETRY_DELAY_S,
) -> ClientSession:
    """Establish and initialize an MCP SSE session with exponential backoff retry."""
    last_exc: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            logger.debug(f"Connecting to MCP server at {mcp_url} (Attempt {attempt}/{retries})")
            transport = sse_client(mcp_url)
            read, write = await transport.__aenter__()
            session = ClientSession(read, write)
            await session.__aenter__()
            await session.initialize()
            session.__transport__ = transport  # type: ignore[attr-defined]
            return session
        except Exception as exc:
            last_exc = exc
            logger.warning("MCP connection attempt %d/%d failed: %s", attempt, retries, exc)
            if attempt < retries:
                await asyncio.sleep(delay * (1.5 ** (attempt - 1)))
    
    err_console.print(f"[bold red]Error:[/bold red] Failed to connect to MCP server at {mcp_url}")
    raise last_exc  # type: ignore[misc]


async def close_session(session: ClientSession) -> None:
    """Safely terminate MCP session and underlying SSE transport."""
    transport = getattr(session, "__transport__", None)
    try:
        await session.__aexit__(None, None, None)
    except Exception as exc:
        logger.warning("Error closing MCP session context: %s", exc)
    
    if transport is not None:
        try:
            await transport.__aexit__(None, None, None)
        except Exception as exc:
            logger.warning("Error terminating SSE transport: %s", exc)


@asynccontextmanager
async def managed_session(
    mcp_url: str = DEFAULT_MCP_URL,
    retries: int = CONNECT_RETRIES,
    delay: float = CONNECT_RETRY_DELAY_S,
) -> AsyncIterator[ClientSession]:
    """Async context manager handling session lifecycle."""
    session = await open_session(mcp_url, retries=retries, delay=delay)
    try:
        yield session
    finally:
        await close_session(session)


# Safe MCP Tool Invocation Helpers

async def call_tool(session: ClientSession, tool: str, **params: Any) -> list[TextContent | ImageContent | EmbeddedResource]:
    """Execute MCP tool with error checking."""
    try:
        result = await session.call_tool(tool, params)
        if result.is_error:
            raise RuntimeError(f"MCP Tool '{tool}' reported error: {result.content}")
        return result.content
    except Exception as exc:
        logger.error(f"Execution failed for tool '{tool}': {exc}")
        raise


def sanitize_filename(url: str, extension: str = "png") -> str:
    """Derive clean, collision-free filename stem from URL."""
    stem = url.removeprefix("https://").removeprefix("http://")
    stem = stem.split("?")[0].split("#")[0]
    clean_stem = "".join(c if c.isalnum() else "-" for c in stem).strip("-")
    return f"{clean_stem}.{extension}"


async def scroll_page_to_bottom(session: ClientSession, pause_ms: int = 500) -> None:
    """Scroll through page incrementally to trigger dynamic and lazy-loaded elements."""
    scroll_js = f"""() => {{
        return new Promise((resolve) => {{
            let totalHeight = 0;
            const distance = 400;
            const timer = setInterval(() => {{
                const scrollHeight = document.body.scrollHeight;
                window.scrollBy(0, distance);
                totalHeight += distance;

                if(totalHeight >= scrollHeight - window.innerHeight){{
                    clearInterval(timer);
                    window.scrollTo(0, 0);
                    resolve(scrollHeight);
                }}
            }}, {pause_ms});
        }});
    }}"""
    await call_tool(session, "browser_evaluate", function=scroll_js)


async def ensure_page_ready(
    session: ClientSession,
    scroll: bool = True,
    pause_ms: int = 500,
    wait_text: str | None = None,
) -> None:
    """Wait for DOM settlement, network idle, font rendering, optional text, and scrolling."""
    logger.info("Waiting for DOM content, network idle, and font loading...")
    
    # 1. Wait for DOM, network idle, web fonts, and force exact screen colors
    readiness_js = """async (page) => {
        await page.waitForLoadState('domcontentloaded');
        await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
        await page.evaluate(() => document.fonts.ready);
        await page.emulateMedia({ media: 'screen' });
        await page.addStyleTag({
            content: '* { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }'
        });
    }"""
    await call_tool(session, "browser_run_code_unsafe", code=readiness_js)

    # 2. Wait for specific visible text if requested
    if wait_text:
        logger.info(f"Waiting for target text: '{wait_text}'")
        await call_tool(session, "browser_wait_for", text=wait_text)

    # 3. Trigger lazy loading via scroll
    if scroll:
        logger.info("Scrolling page to trigger lazy-loaded assets...")
        await scroll_page_to_bottom(session, pause_ms=pause_ms)


# Action Commands

async def capture_screenshot(
    session: ClientSession,
    url: str,
    output_dir: Path = DEFAULT_OUT_DIR,
    scroll: bool = True,
    pause_ms: int = 500,
    wait_text: str | None = None,
) -> Path:
    """Navigate, wait for page ready & scroll, and capture screenshot directly to disk volume."""
    logger.info(f"Navigating to {url}")
    await call_tool(session, "browser_navigate", url=url)

    # Prepare page state prior to capture
    await ensure_page_ready(session, scroll=scroll, pause_ms=pause_ms, wait_text=wait_text)

    filename = sanitize_filename(url, extension="png")
    container_file_path = str(CONTAINER_SCREENSHOT_DIR / filename)

    screenshot_options = {
        "path": container_file_path,
        "fullPage": True,
    }

    screenshot_render_code = f"""async (page) => {{
        await page.screenshot({json.dumps(screenshot_options)});
    }}"""

    logger.info(f"Taking full-page screenshot inside container at {container_file_path}")
    await call_tool(session, "browser_run_code_unsafe", code=screenshot_render_code)

    output_dir.mkdir(parents=True, exist_ok=True)
    host_file_path = output_dir / filename

    if not host_file_path.exists():
        raise FileNotFoundError(
            f"Screenshot generation completed inside container at '{container_file_path}', "
            f"but file is missing at host mount '{host_file_path}'."
        )

    return host_file_path


async def capture_pdf(
    session: ClientSession,
    url: str,
    output_dir: Path = DEFAULT_PDF_DIR,
    scroll: bool = True,
    pause_ms: int = 500,
) -> Path:
    """Render page to PDF with screen colors and explicit DOM/network settlement."""
    logger.info(f"Navigating to {url}")
    await call_tool(session, "browser_navigate", url=url)

    # Prepare page state prior to render
    await ensure_page_ready(session, scroll=scroll, pause_ms=pause_ms)

    filename = sanitize_filename(url, extension="pdf")
    container_file_path = str(CONTAINER_PDF_DIR / filename)

    pdf_options = {
        "path": container_file_path,
        "printBackground": True,
        "format": "A4",
        "margin": {"top": "1cm", "right": "1cm", "bottom": "1cm", "left": "1cm"},
        "preferCSSPageSize": True,
    }
    
    pdf_render_code = f"""async (page) => {{
        await page.pdf({json.dumps(pdf_options)});
    }}"""

    logger.info(f"Generating PDF inside container at {container_file_path}")
    await call_tool(session, "browser_run_code_unsafe", code=pdf_render_code)

    output_dir.mkdir(parents=True, exist_ok=True)
    host_file_path = output_dir / filename

    if not host_file_path.exists():
        raise FileNotFoundError(
            f"PDF generation completed inside container at '{container_file_path}', "
            f"but file is missing at host mount '{host_file_path}'."
        )

    return host_file_path


# CLI Interface Entrypoints

@app.command("screenshot")
def cmd_screenshot(
    url: Annotated[str, typer.Argument(help="Target URL to capture.")],
    scroll: Annotated[bool, typer.Option("--scroll/--no-scroll", help="Trigger page scroll to resolve lazy loading.")] = True,
    pause_ms: Annotated[int, typer.Option("--pause", help="Pause duration per scroll step in ms.")] = 500,
    wait_for: Annotated[str | None, typer.Option("--wait-for", "-w", help="Text element to wait for prior to rendering.")] = None,
    out_dir: Annotated[Path, typer.Option("--out-dir", "-o", help="Target output directory.")] = DEFAULT_OUT_DIR,
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP SSE endpoint URL.")] = DEFAULT_MCP_URL,
) -> None:
    """Capture a high-resolution screenshot of a webpage."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            out_file = await capture_screenshot(
                session, url, output_dir=out_dir, scroll=scroll, pause_ms=pause_ms, wait_text=wait_for
            )
            console.print(f"[bold green]Successfully saved screenshot:[/bold green] {out_file}")

    asyncio.run(run())


@app.command("pdf")
def cmd_pdf(
    url: Annotated[str, typer.Argument(help="Target URL to render as PDF.")],
    scroll: Annotated[bool, typer.Option("--scroll/--no-scroll", help="Control pre-render scrolling.")] = True,
    pause_ms: Annotated[int, typer.Option("--pause", help="Pause duration per scroll step in ms.")] = 500,
    out_dir: Annotated[Path, typer.Option("--out-dir", "-o", help="Target output directory.")] = DEFAULT_PDF_DIR,
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP SSE endpoint URL.")] = DEFAULT_MCP_URL,
) -> None:
    """Render and capture target URL as a PDF document."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            out_file = await capture_pdf(session, url, output_dir=out_dir, scroll=scroll, pause_ms=pause_ms)
            console.print(f"[bold green]Successfully rendered PDF:[/bold green] {out_file}")

    asyncio.run(run())


@app.command("tools")
def cmd_list_tools(
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP SSE endpoint URL.")] = DEFAULT_MCP_URL,
) -> None:
    """List all supported capabilities exposed by the active MCP server."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            tools = await session.list_tools()
            table = Table(title="Available MCP Tools", show_header=True, header_style="bold magenta")
            table.add_column("Tool Name", style="bold cyan", no_wrap=True)
            table.add_column("Description")
            for tool in tools.tools:
                table.add_row(tool.name, tool.description or "")
            console.print(table)

    asyncio.run(run())


if __name__ == "__main__":
    app()