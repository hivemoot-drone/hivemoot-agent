"""Tests for hivemoot_agent CLI commands."""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from hivemoot_agent.__main__ import main, build_parser


# ── extract response tests ────────────────────────────────────────


def test_extract_response_claude_log(tmp_path):
    log_file = tmp_path / "agent.log"
    log_file.write_text(
        '{"type":"system","subtype":"init","session_id":"abc"}\n'
        '{"type":"result","result":"Hello from Claude"}\n'
    )
    args = build_parser().parse_args([
        "extract", "response",
        "--provider", "claude",
        "--log-file", str(log_file),
    ])
    assert hasattr(args, "func")
    # Capture stdout.
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = args.func(args)
    assert rc == 0
    assert buf.getvalue() == "Hello from Claude"


def test_extract_response_missing_file(tmp_path):
    args = build_parser().parse_args([
        "extract", "response",
        "--provider", "claude",
        "--log-file", str(tmp_path / "nonexistent.log"),
    ])
    rc = args.func(args)
    assert rc == 1


def test_extract_response_empty_log(tmp_path):
    log_file = tmp_path / "empty.log"
    log_file.write_text("")
    args = build_parser().parse_args([
        "extract", "response",
        "--provider", "claude",
        "--log-file", str(log_file),
    ])
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = args.func(args)
    assert rc == 0
    assert buf.getvalue() == ""


def test_extract_response_provider_default(tmp_path):
    log_file = tmp_path / "agent.log"
    log_file.write_text('{"type":"result","result":"default provider"}\n')
    args = build_parser().parse_args([
        "extract", "response",
        "--log-file", str(log_file),
    ])
    assert args.provider == "claude"


if __name__ == "__main__":
    import inspect

    passed = 0
    failed = 0
    for name, func in sorted(inspect.getmembers(sys.modules[__name__], inspect.isfunction)):
        if not name.startswith("test_"):
            continue
        try:
            sig = inspect.signature(func)
            if "tmp_path" in sig.parameters:
                with tempfile.TemporaryDirectory() as td:
                    from pathlib import Path
                    func(Path(td))
            else:
                func()
            print(f"  \u2713 {name}")
            passed += 1
        except Exception as exc:
            print(f"  \u2717 {name}: {exc}")
            failed += 1

    print(f"\n{passed} passed, {failed} failed")
    if failed:
        sys.exit(1)
