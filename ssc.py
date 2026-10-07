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
"""Playwright-based MCP client for screenshot and PDF captures with DuckDuckGo AutoConsent and dynamic popup cleanup."""

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
from mcp.client.streamable_http import streamable_http_client as streamablehttp_client
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
    name="ssc",
    help="Playwright-based MCP client for screenshot and PDF captures with autoconsent and overlay cleanup.",
    add_completion=False,
    context_settings={"help_option_names": ["-h", "--help"]},
)
console = Console()
err_console = Console(stderr=True)

# Path and URL defaults aligned with Makefile & docker-compose.yml
DEFAULT_MCP_URL = os.getenv("MCP_SERVER_URL", "http://localhost:3000/mcp")
CONTAINER_SCREENSHOT_DIR = Path("/screenshots")
DEFAULT_OUT_DIR = Path(os.getenv("SCREENSHOTS_DIR", "./screenshots"))
CONTAINER_PDF_DIR = Path("/pdfs")
DEFAULT_PDF_DIR = Path(os.getenv("PDFS_DIR", "./pdfs"))
DEFAULT_WORKSPACE_DIR = Path(os.getenv("WORKSPACE_DIR", "./workspace"))

CONNECT_RETRIES = 5
CONNECT_RETRY_DELAY_S = 2.0


# Embedded JS Engine: Imports @duckduckgo/autoconsent, initializes rules runner, and runs fallback DOM cleaner
AUTOCONSENT_AND_POPUP_DISMISSER_JS = """async (page, options) => {
    const { customSelectors = [] } = options || {};

    // 1. Load and execute full DuckDuckGo AutoConsent ruleset in Node/Playwright context
    try {
        await page.evaluate(async () => {
            // Check if @duckduckgo/autoconsent bundle or module is loaded
            let AutoConsentClass = window.autoconsent?.AutoConsent || window.AutoConsent;
            
            if (!AutoConsentClass) {
                try {
                    // Import module directly if in module environment
                    const module = await import('@duckduckgo/autoconsent');
                    AutoConsentClass = module.AutoConsent || module.default;
                } catch (e) {}
            }

            if (AutoConsentClass) {
                const autoconsent = new AutoConsentClass({
                    config: {
                        enabled: true,
                        autoAction: 'optOut', // Automatically opt-out/reject non-essential cookies
                        enableCosmeticRules: true
                    }
                });

                // Attach message listener required by AutoConsent rule execution cycle
                if (typeof autoconsent.init === 'function') {
                    await autoconsent.init();
                }
                if (typeof autoconsent.start === 'function') {
                    await autoconsent.start();
                }
            }
        });
    } catch (err) {
        console.warn('AutoConsent module initialization note:', err.message);
    }

    // 2. Continuous DOM observer and fallback clicker for custom popups and CMPs
    await page.evaluate(async (customSels) => {
        window.__dismissOverlays = () => {
            const closeSelectors = [
                // OneTrust / CookiePro / Cookiebot rules (cncf.io, etc.)
                '#onetrust-accept-btn-handler',
                '#onetrust-reject-all-handler',
                '#accept-recommended-btn-handler',
                '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
                '.cc-accept-all',
                '.cc-dismiss',
                
                // Common interactive consent elements
                'button[aria-label*="close" i]',
                'button[aria-label*="dismiss" i]',
                'button[aria-label*="accept" i]',
                'button[class*="close" i]',
                'button[class*="dismiss" i]',
                'button[id*="accept" i]',
                '.button.button-primary-text',
                '[data-testid*="close" i]',
                '.modal-close',
                '.popup-close',
                '.overlay-close',
                ...customSels
            ];

            // Click matching close / accept / opt-out buttons
            for (const sel of closeSelectors) {
                try {
                    const elements = document.querySelectorAll(sel);
                    elements.forEach((el) => {
                        if (el && el.offsetWidth > 0 && el.offsetHeight > 0) {
                            el.click();
                        }
                    });
                } catch (e) {}
            }

            // Hide large blocking fixed/absolute overlays
            const allNodes = document.querySelectorAll('div, section, aside, dialog, iframe');
            allNodes.forEach((node) => {
                const style = window.getComputedStyle(node);
                const isFixedOrSticky = style.position === 'fixed' || style.position === 'sticky';
                const hasHighZIndex = parseInt(style.zIndex, 10) > 90;

                if (isFixedOrSticky && hasHighZIndex) {
                    const rect = node.getBoundingClientRect();
                    const coversViewport = (rect.width * rect.height) > (window.innerWidth * window.innerHeight * 0.25);
                    if (coversViewport) {
                        node.style.display = 'none';
                        node.setAttribute('aria-hidden', 'true');
                    }
                }
            });

            // Restore screen scrollability if locked by modal backdrop
            document.documentElement.style.overflow = 'auto';
            document.body.style.overflow = 'auto';
            document.body.style.position = 'static';
        };

        // Run immediate pass
        window.__dismissOverlays();

        // Attach MutationObserver to clear delayed popups as page mutates or scrolls
        if (!window.__popupObserver) {
            window.__popupObserver = new MutationObserver(() => {
                window.__dismissOverlays();
            });
            window.__popupObserver.observe(document.body, { childList: true, subtree: true });
        }
    }, customSelectors);
}"""


# Connection Lifecycle Management

async def open_session(
    mcp_url: str,
    retries: int = CONNECT_RETRIES,
    delay: float = CONNECT_RETRY_DELAY_S,
) -> ClientSession:
    """Establish and initialize an MCP streamable-HTTP session with exponential backoff retry."""
    last_exc: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            logger.debug(f"Connecting to MCP server at {mcp_url} (Attempt {attempt}/{retries})")
            transport = streamablehttp_client(mcp_url)
            read, write, _ = await transport.__aenter__()
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
    """Derive clean, collision-free filename stem from URL.

    For file:// URLs the basename without extension is used so that
    file:///html/foo.html produces foo.png rather than file---html-foo-html.png.
    """
    if url.startswith("file://"):
        stem = Path(url.removeprefix("file://")).stem
        return f"{stem}.{extension}"
    stem = url.removeprefix("https://").removeprefix("http://")
    stem = stem.split("?")[0].split("#")[0]
    clean_stem = "".join(c if c.isalnum() else "-" for c in stem).strip("-")
    return f"{clean_stem}.{extension}"


def load_storage_state(state_path: Path) -> dict[str, Any]:
    """Load and parse Playwright storageState JSON file."""
    if not state_path.exists():
        raise FileNotFoundError(f"Specified storage state file not found: {state_path}")
    with open(state_path, "r", encoding="utf-8") as f:
        return json.load(f)


async def apply_storage_state(
    session: ClientSession,
    url: str,
    state_path: Path,
) -> None:
    """Inject cookies and localStorage into browser context prior to target interaction."""
    logger.info(f"Applying storage state from {state_path}")
    state = load_storage_state(state_path)

    cookies = state.get("cookies", [])
    origins = state.get("origins", [])

    if cookies:
        cookies_js = f"""async (page) => {{
            const context = page.context();
            await context.addCookies({json.dumps(cookies)});
        }}"""
        await call_tool(session, "browser_run_code_unsafe", code=cookies_js)
        logger.info(f"Injected {len(cookies)} cookies into browser context.")

    if origins:
        await call_tool(session, "browser_navigate", url=url)
        
        storage_js = f"""async (page) => {{
            const origins = {json.dumps(origins)};
            const currentUrl = page.url();
            
            for (const originState of origins) {{
                if (currentUrl.startsWith(originState.origin)) {{
                    await page.evaluate((items) => {{
                        for (const item of items) {{
                            localStorage.setItem(item.name, item.value);
                        }}
                    }}, originState.localStorage || []);
                }}
            }}
        }}"""
        await call_tool(session, "browser_run_code_unsafe", code=storage_js)
        logger.info("Injected LocalStorage keys into target origin.")


async def scroll_page_to_bottom(session: ClientSession, pause_ms: int = 500) -> None:
    """Scroll through page incrementally to trigger dynamic elements and ensure continuous overlay cleanup."""
    scroll_js = f"""() => {{
        return new Promise((resolve) => {{
            let totalHeight = 0;
            const distance = 400;
            const timer = setInterval(() => {{
                const scrollHeight = document.body.scrollHeight;
                window.scrollBy(0, distance);
                totalHeight += distance;

                if (window.__dismissOverlays) {{
                    window.__dismissOverlays();
                }}

                if(totalHeight >= scrollHeight - window.innerHeight){{
                    clearInterval(timer);
                    window.scrollTo(0, 0);
                    if (window.__dismissOverlays) window.__dismissOverlays();
                    resolve(scrollHeight);
                }}
            }}, {pause_ms});
        }});
    }}"""
    await call_tool(session, "browser_evaluate", function=scroll_js)


async def ensure_page_ready(
    session: ClientSession,
    url: str,
    scroll: bool = True,
    pause_ms: int = 500,
    wait_text: str | None = None,
    dismiss_popups: bool = True,
    custom_selectors: list[str] | None = None,
    storage_state_path: Path | None = None,
) -> None:
    """Wait for DOM settlement, apply session state, autoconsent, scroll, and clear popups."""
    
    if storage_state_path:
        await apply_storage_state(session, url=url, state_path=storage_state_path)

    logger.info("Waiting for DOM content, network idle, and font loading...")
    
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

    if dismiss_popups:
        logger.info("Injecting AutoConsent and dynamic popup cleanup listeners...")
        opts = {"customSelectors": custom_selectors or []}
        code_str = f"async (page) => {{ const fn = {AUTOCONSENT_AND_POPUP_DISMISSER_JS}; await fn(page, {json.dumps(opts)}); }}"
        await call_tool(session, "browser_run_code_unsafe", code=code_str)

    if wait_text:
        logger.info(f"Waiting for target text: '{wait_text}'")
        await call_tool(session, "browser_wait_for", text=wait_text)

    if scroll:
        logger.info("Scrolling page to trigger lazy-loaded assets and clear delayed popups...")
        await scroll_page_to_bottom(session, pause_ms=pause_ms)

    if dismiss_popups:
        await call_tool(session, "browser_evaluate", function="() => { if (window.__dismissOverlays) window.__dismissOverlays(); }")


# Core Action Handlers

async def capture_screenshot(
    session: ClientSession,
    url: str,
    output_dir: Path = DEFAULT_OUT_DIR,
    scroll: bool = True,
    pause_ms: int = 500,
    wait_text: str | None = None,
    dismiss_popups: bool = True,
    custom_selectors: list[str] | None = None,
    storage_state_path: Path | None = None,
) -> Path:
    """Navigate, wait for page ready & scroll, clear popups, and capture screenshot."""
    logger.info(f"Navigating to {url}")
    await call_tool(session, "browser_navigate", url=url)

    await ensure_page_ready(
        session,
        url=url,
        scroll=scroll,
        pause_ms=pause_ms,
        wait_text=wait_text,
        dismiss_popups=dismiss_popups,
        custom_selectors=custom_selectors,
        storage_state_path=storage_state_path,
    )

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
    dismiss_popups: bool = True,
    custom_selectors: list[str] | None = None,
    storage_state_path: Path | None = None,
) -> Path:
    """Render page to PDF with screen colors, DOM settlement, and popup removal."""
    logger.info(f"Navigating to {url}")
    await call_tool(session, "browser_navigate", url=url)

    await ensure_page_ready(
        session,
        url=url,
        scroll=scroll,
        pause_ms=pause_ms,
        dismiss_popups=dismiss_popups,
        custom_selectors=custom_selectors,
        storage_state_path=storage_state_path,
    )

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


# CLI Command Entrypoints

@app.command("screenshot")
def cmd_screenshot(
    url: Annotated[str, typer.Argument(help="Target URL to capture.")],
    storage_state: Annotated[Path | None, typer.Option("--storage-state", "-s", help="Path to JSON file containing cookies & localStorage state.")] = None,
    scroll: Annotated[bool, typer.Option("--scroll/--no-scroll", help="Trigger page scroll to resolve lazy loading.")] = True,
    pause_ms: Annotated[int, typer.Option("--pause", help="Pause duration per scroll step in ms.")] = 500,
    wait_for: Annotated[str | None, typer.Option("--wait-for", "-w", help="Text element to wait for prior to rendering.")] = None,
    dismiss_popups: Annotated[bool, typer.Option("--dismiss-popups/--no-dismiss-popups", help="Automatically dismiss cookie consent and delayed popups.")] = True,
    custom_selector: Annotated[list[str] | None, typer.Option("--custom-selector", "-c", help="Custom CSS selectors to click for specific site popups.")] = None,
    out_dir: Annotated[Path, typer.Option("--out-dir", "-o", help="Target output directory.")] = DEFAULT_OUT_DIR,
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP endpoint URL.")] = DEFAULT_MCP_URL,
) -> None:
    """Capture a high-resolution full-page screenshot of a webpage."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            out_file = await capture_screenshot(
                session,
                url,
                output_dir=out_dir,
                scroll=scroll,
                pause_ms=pause_ms,
                wait_text=wait_for,
                dismiss_popups=dismiss_popups,
                custom_selectors=custom_selector,
                storage_state_path=storage_state,
            )
            console.print(f"[bold green]Successfully saved screenshot:[/bold green] {out_file}")

    asyncio.run(run())


@app.command("pdf")
def cmd_pdf(
    url: Annotated[str, typer.Argument(help="Target URL to render as PDF.")],
    storage_state: Annotated[Path | None, typer.Option("--storage-state", "-s", help="Path to JSON file containing cookies & localStorage state.")] = None,
    scroll: Annotated[bool, typer.Option("--scroll/--no-scroll", help="Control pre-render scrolling.")] = True,
    pause_ms: Annotated[int, typer.Option("--pause", help="Pause duration per scroll step in ms.")] = 500,
    dismiss_popups: Annotated[bool, typer.Option("--dismiss-popups/--no-dismiss-popups", help="Automatically dismiss cookie consent and delayed popups.")] = True,
    custom_selector: Annotated[list[str] | None, typer.Option("--custom-selector", "-c", help="Custom CSS selectors to click for specific site popups.")] = None,
    out_dir: Annotated[Path, typer.Option("--out-dir", "-o", help="Target output directory.")] = DEFAULT_PDF_DIR,
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP endpoint URL.")] = DEFAULT_MCP_URL,
) -> None:
    """Render and capture target URL as a PDF document."""
    async def run() -> None:
        async with managed_session(mcp_url) as session:
            out_file = await capture_pdf(
                session,
                url,
                output_dir=out_dir,
                scroll=scroll,
                pause_ms=pause_ms,
                dismiss_popups=dismiss_popups,
                custom_selectors=custom_selector,
                storage_state_path=storage_state,
            )
            console.print(f"[bold green]Successfully rendered PDF:[/bold green] {out_file}")

    asyncio.run(run())


@app.command("tools")
def cmd_list_tools(
    mcp_url: Annotated[str, typer.Option("--url", "-u", help="MCP endpoint URL.")] = DEFAULT_MCP_URL,
) -> None:
    """List all supported capabilities exposed by the active Playwright MCP server."""
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