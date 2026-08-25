#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import plistlib
import re
import tempfile
from pathlib import Path


PROVIDER_BLOCK = '''[model_providers.deepseek]
name = "DeepSeek via local Responses proxy"
base_url = "http://127.0.0.1:4878/v1"
wire_api = "responses"
supports_websockets = false
request_max_retries = 4
stream_max_retries = 8
stream_idle_timeout_ms = 600000

[model_providers.deepseek.auth]
command = "/usr/bin/printf"
args = ["codex-deepseek-local"]
refresh_interval_ms = 0
timeout_ms = 5000
'''


def remove_deepseek_provider(text: str) -> str:
    lines = text.splitlines(keepends=True)
    result: list[str] = []
    skip = False
    table_pattern = re.compile(r"^\s*\[([^]]+)]\s*(?:#.*)?$")
    for line in lines:
        match = table_pattern.match(line.rstrip("\r\n"))
        if match:
            table = match.group(1).strip()
            skip = table == "model_providers.deepseek" or table.startswith("model_providers.deepseek.")
        if not skip:
            result.append(line)
    return "".join(result).rstrip() + "\n"


def root_value(text: str, key: str) -> str | None:
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*(.+?)\s*(?:#.*)?$')
    for line in text.splitlines():
        if line.lstrip().startswith("["):
            break
        match = pattern.match(line)
        if match:
            return match.group(0).strip()
    return None


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def normalize_legacy_deepseek_max(text: str) -> str:
    """Replace the unsupported Codex-side max value only for active DeepSeek."""
    table_match = re.search(r"^\s*\[", text, re.MULTILINE)
    root_end = table_match.start() if table_match else len(text)
    root = text[:root_end]
    remainder = text[root_end:]
    provider_match = re.search(r'^\s*model_provider\s*=\s*"([^"]+)"', root, re.MULTILINE)
    if not provider_match or provider_match.group(1) != "deepseek":
        return text
    normalized = re.sub(
        r'^(\s*model_reasoning_effort\s*=\s*)"max"(\s*(?:#.*)?)$',
        r'\1"xhigh"\2',
        root,
        count=1,
        flags=re.MULTILINE,
    )
    return normalized + remainder


def patch_config(config_path: Path, chatgpt_state_path: Path) -> None:
    original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    if not chatgpt_state_path.exists():
        saved = [
            value
            for key in ("model", "model_reasoning_effort", "service_tier")
            if (value := root_value(original, key))
        ]
        atomic_write(chatgpt_state_path, (("\n".join(saved) + "\n") if saved else "").encode(), 0o600)
    original = normalize_legacy_deepseek_max(original)
    patched = remove_deepseek_provider(original).rstrip() + "\n\n" + PROVIDER_BLOCK
    atomic_write(config_path, patched.encode("utf-8"), 0o600)


def write_launch_agent(path: Path, proxy_path: Path, log_dir: Path) -> None:
    payload = {
        "Label": "local.codex-deepseek-proxy",
        "ProgramArguments": [
            "/usr/bin/python3",
            str(proxy_path),
            "--host", "127.0.0.1",
            "--port", "4878",
            "--keychain-service", "codex-deepseek-api-key",
            "--local-token", "codex-deepseek-local",
            "--thinking", "enabled",
            "--connect-timeout", "8",
            "--stream-idle-timeout", "180",
            "--response-timeout", "300",
            "--health-read-timeout", "15",
        ],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 1,
        "ProcessType": "Background",
        "WorkingDirectory": str(proxy_path.parent),
        "StandardOutPath": str(log_dir / "deepseek-proxy.out.log"),
        "StandardErrorPath": str(log_dir / "deepseek-proxy.err.log"),
        "Umask": 0o077,
    }
    atomic_write(path, plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False), 0o600)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", type=Path, required=True)
    parser.add_argument("--launch-agent", type=Path, required=True)
    args = parser.parse_args()
    codex_home = args.codex_home.expanduser().resolve()
    launch_agent_path = args.launch_agent.expanduser()
    log_dir = codex_home / "log"
    log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = codex_home / "config.toml"
    patch_config(config_path, codex_home / "chatgpt.activation.toml")
    write_launch_agent(
        launch_agent_path,
        codex_home / "deepseek-proxy" / "proxy.py",
        log_dir,
    )


if __name__ == "__main__":
    main()
