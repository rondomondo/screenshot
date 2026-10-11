# Project

This CLAUDE.md applies to all projects and directories (including subdirectories) that contain this file,
unless a path is excluded by `.claudeignore`.

## Context exclusions

A `.claudeignore` file in the project root lists glob patterns for paths Claude should not read or index
(dependencies, build output, secrets, large data files, etc.). Treat `.claudeignore` as authoritative:
if a path matches, do not read or summarise its contents.

## Memory

Project-level memories are stored under `~/.claude/projects/` and loaded automatically. Global preferences
and cross-project rules live in `~/.claude/`. When a task references prior decisions or past context,
check those memory files before asking the user to re-explain.

## Writing style

- Never use em dashes (--); use commas, parentheses, hyphens, or separate sentences instead
- British spelling: `realise` not `realize`, `colour` not `color`, etc.
- Stay within the ASCII character set
- No comments explaining what code does -- only why (hidden constraints, non-obvious invariants)

## Code style

- `ruff` for linting/formatting (`line-length = 119`)
- `mypy` with `strict = false` and `ignore_missing_imports = true`
- Line length: 119 characters max
- Python 3.12+ with full type annotations
- Import order: standard lib, third-party, local
- Naming: `snake_case` for functions/variables, `PascalCase` for classes
- Use Pydantic v2 for data validation and schemas
- Use FastAPI for HTTP endpoints
- Use `pathlib.Path` throughout; never raw string paths
- Use `copy.deepcopy` before mutating shared data structures
- All file I/O must use `encoding='utf-8'`; JSON output uses `ensure_ascii=False`
- Magic numbers must be named constants (`ALL_CAPS`)
- Private helpers are prefixed with `_`; public API is clearly separated

## Type hints

- All public function signatures must have full type hints
- Use modern union syntax: `str | None`, `list[str]`, `dict[str, Any]` -- not `Optional[str]` or `List[str]`
- `from __future__ import annotations` is not currently used; explicit imports from `typing` are required
  only for constructs unavailable as builtins (e.g. `Any`, `Union` in complex cases)
- Buffer parameters should be typed `BytesIO | bytes | str | Path` as appropriate -- not `Optional[bytes]`

## Async

- Prefer `async`/`await` for all I/O-bound work (network calls, file reads in hot paths)
- Use `httpx` (async-capable) instead of `requests` for HTTP calls
- Entry points use `asyncio.run(main())` -- do not call `asyncio.get_event_loop()` directly
- Synchronous CLI scripts that do minimal I/O are acceptable without async

## Logging

- Library and API code must use the `logging` module -- never `print` for diagnostics
- CLI scripts may use `print(..., file=sys.stderr)` for errors and warnings, `print()` for output data
- Do not configure logging inside library modules; leave that to the caller or entry point
- Log levels: `DEBUG` for trace/detail, `INFO` for progress, `WARNING` for recoverable issues, `ERROR` for failures

## Error handling

- Catch specific exceptions -- never bare `except:` or `except Exception:` without re-raising or logging
- Validate inputs early; fail fast with a clear message before doing any work
- CLI scripts exit with code 0 on success, 1 on failure -- use `sys.exit(1)` not `raise SystemExit`
- Optional third-party dependencies are imported inside a `try/except ImportError` block with a fallback or
  a clear error message

## CLI scripts

- Use `argparse` with grouped arguments and sensible defaults
- Validate all arguments in `main()` before any processing begins
- Scripts designed for pipeline composition read from stdin, write data to stdout, and send errors to stderr
- Entry point: `if __name__ == "__main__": main()`
- Always include `-h` as a short alias for `--help`; for `argparse` pass `add_help=True` (default) and add `formatter_class`; for `typer` pass `context_settings={"help_option_names": ["-h", "--help"]}` to the `Typer()` constructor

## Standalone scripts (uv shebang)

Scripts intended to run directly with `uv run` must use the inline script metadata shebang format:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "some-package>=1.0.0",
# ]
# ///
```

Always use this form for any script that carries its own dependency list. Never use a bare `#!/usr/bin/env python3` shebang on such scripts.

## Section comments

Use plain section headings without decorator lines:

```python
# Section title
```

Not:

```python
# ---------------------------------------------------------------------------
# Section title
# ---------------------------------------------------------------------------
```

The dashes cause rendering problems in some editors and CI log viewers.

## Docstrings: Google style

All public functions must have Google-style docstrings.

```python
def fn(url: str, overwrite: bool = False) -> dict:
    """One-line summary

    Optional longer description when intent is non-obvious.

    Args:
        url: The redirect destination URL.
        overwrite: When True, silently replace an existing key.

    Returns:
        A dict suitable for passing to put_object as extra kwargs.

    Raises:
        ValueError: If url uses an unsupported scheme.
    """
```

Rules:

- First line is a short imperative summary with no trailing period
- `Args:`, `Returns:`, `Raises:` sections only when present
- Parameter descriptions start lowercase
- Omit obvious sections (no `Returns:` on a `None`-returning function)

## Running tests

Use `pytest` exclusively -- no other test runner. Run the full suite with:

```bash
uv run pytest
```

Test location and `pythonpath` settings are configured in `pyproject.toml`. Check that file for the
canonical pytest root and any path configuration before adjusting test commands.

Every project must have tests with meaningful coverage. When adding new functionality, add
corresponding tests. When fixing a bug, add a regression test. Aim for coverage of all public
functions and edge cases at boundaries.

## Virtual environment

The project uses `uv` for dependency management and virtual environments:

```bash
uv sync
uv sync --extra dev   # include dev/test dependencies
```

To run a one-off command inside the project environment without activating it:

```bash
uv run <command>
```

To add or remove dependencies, use `uv add` / `uv remove` -- never edit `pyproject.toml`
dependency lists by hand. The `.venv/` directory is excluded from context via `.claudeignore`.

Do not use `pip`, `pip install`, `python -m venv`, or `virtualenv` in this project.

## Git hooks

Every project must have a `.githooks/` directory at the root with a `commit-msg` hook that
enforces Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/).

The hook must:
- Reject commits whose subject line does not match the pattern:
  `<type>[optional scope]: <description>`
- Accept these types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, `revert`
- Print a clear error message showing the expected format when it rejects a commit

Wire the hooks directory in the Makefile so `make install` (or equivalent setup target) runs:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/commit-msg
```

## README

Every project must have a `README.md` at the top level. Its content must describe the actual
project it lives in -- not a template, not placeholder text. At minimum it should cover:

- What the project does and why it exists
- How to install and run it locally (using `uv`)
- How to run the tests

Keep the README current: when functionality changes, update it in the same commit.

## .gitignore

Every project must have a `.gitignore` at the top level. At minimum it must exclude:

- `.venv/`
- `__pycache__/` and `*.pyc`
- `*.egg-info/`
- `dist/` and `build/`
- `.coverage` and `htmlcov/`
- `.env` and `*.local`
- `node_modules/` (if applicable)

## Makefiles

Before running any management or build command manually, check the root `Makefile` and, for
skill-specific work, `skills/<name>/Makefile`. Common tasks (installing skills, zipping, plugin
generation) are already captured there. Run `make help` for a summary of available targets.

When editing a Makefile, actively consolidate: extract shared values into variables at the top,
remove targets that duplicate other targets or that are no longer called, and merge targets that
do the same job under different names. A Makefile that grows without pruning becomes a source of
confusion -- keep it lean.
