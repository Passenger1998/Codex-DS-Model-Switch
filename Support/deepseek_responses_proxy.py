#!/usr/bin/env python3
"""Local OpenAI Responses API to DeepSeek Chat Completions adapter.

The server binds to loopback only, gets the upstream API key from macOS
Keychain, and never writes credentials to disk or logs them.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import hmac
import json
import os
import queue
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from credential_profiles import (
    DEFAULT_PROFILE_NAME,
    LEGACY_PROFILE_ID,
    CredentialProfileError,
    load_state,
    migrated_state,
    resolve_profile,
)


VERSION = "1.2.0"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 4878
DEFAULT_UPSTREAM = "https://api.deepseek.com/chat/completions"
DEFAULT_KEYCHAIN_SERVICE = "codex-deepseek-api-key"
DEFAULT_LOCAL_TOKEN = "codex-deepseek-local"
MAX_REQUEST_BYTES = 32 * 1024 * 1024
MAX_TOOLS = 128
TOOL_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}


# Codex `reasoning.effort` is the single source of truth for each request.
# Map it to the DeepSeek V4 Pro upstream effort per request, never a fixed
# global proxy state. Codex exposes "high" and "xhigh" only.
CODEX_EFFORT_TO_UPSTREAM = {"high": "high", "xhigh": "max"}
DEFAULT_UPSTREAM_EFFORT = "high"
ACCEPTED_CODEX_EFFORTS = ["high", "xhigh"]


def upstream_effort_for(codex_effort: str | None) -> str:
    return CODEX_EFFORT_TO_UPSTREAM.get(codex_effort, DEFAULT_UPSTREAM_EFFORT)


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def content_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, (int, float, bool)):
        return str(content)
    if isinstance(content, list):
        chunks: list[str] = []
        for part in content:
            if isinstance(part, str):
                chunks.append(part)
            elif isinstance(part, dict):
                value = part.get("text", part.get("content", part.get("output", "")))
                if isinstance(value, str):
                    chunks.append(value)
                elif value not in (None, ""):
                    chunks.append(compact_json(value))
        return "\n".join(chunk for chunk in chunks if chunk)
    if isinstance(content, dict):
        for key in ("text", "content", "output"):
            if key in content:
                return content_text(content[key])
    return compact_json(content)


def safe_tool_name(name: str) -> str:
    if TOOL_NAME_RE.fullmatch(name):
        return name
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "_", name).strip("_") or "tool"
    digest = hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]
    return f"{cleaned[:48]}_{digest}"[:64]


def recent_user_text(body: dict[str, Any]) -> str:
    chunks: list[str] = []
    input_value = body.get("input")
    if isinstance(input_value, str):
        return input_value.lower()
    if isinstance(input_value, list):
        for item in reversed(input_value):
            if isinstance(item, dict) and item.get("role") == "user":
                chunks.append(content_text(item.get("content")))
                if len(chunks) == 4:
                    break
    return "\n".join(reversed(chunks)).lower()


def tool_score(tool: dict[str, Any], prompt: str, index: int) -> tuple[int, int]:
    name = str(tool.get("name") or tool.get("function", {}).get("name") or "")
    description = str(tool.get("description") or tool.get("function", {}).get("description") or "")
    lowered = name.lower()
    score = 0
    core_hints = (
        "shell", "exec", "apply_patch", "read_file", "write_file", "search", "find", "rg",
        "browser", "computer", "image", "view", "git", "test",
    )
    if any(hint in lowered for hint in core_hints):
        score += 100
    prompt_terms = {term for term in re.findall(r"[a-z0-9_\u4e00-\u9fff]{3,}", prompt) if len(term) >= 3}
    haystack = f"{lowered} {description.lower()}"
    score += min(80, sum(8 for term in prompt_terms if term in haystack))
    return score, -index


def select_tools(tools: list[dict[str, Any]], body: dict[str, Any]) -> list[dict[str, Any]]:
    if len(tools) <= MAX_TOOLS:
        return tools
    prompt = recent_user_text(body)
    ranked = sorted(enumerate(tools), key=lambda pair: tool_score(pair[1], prompt, pair[0]), reverse=True)
    chosen_indexes = {index for index, _ in ranked[:MAX_TOOLS]}
    return [tool for index, tool in enumerate(tools) if index in chosen_indexes]


@dataclass(frozen=True)
class ProxyConfig:
    host: str
    port: int
    upstream_url: str
    keychain_service: str
    local_token: str
    thinking: str
    connect_timeout: float
    stream_idle_timeout: float
    response_timeout: float
    health_read_timeout: float
    credential_profiles_file: str = ""


@dataclass(frozen=True)
class ProxyEndpoint:
    source: str
    host: str
    port: int

    @property
    def url(self) -> str:
        host = f"[{self.host}]" if ":" in self.host and not self.host.startswith("[") else self.host
        return f"http://{host}:{self.port}"

    @property
    def route_name(self) -> str:
        return f"macOS {self.source} system proxy"


@dataclass(frozen=True)
class MacOSProxySettings:
    http: ProxyEndpoint | None = None
    https: ProxyEndpoint | None = None

    def for_scheme(self, scheme: str) -> ProxyEndpoint | None:
        if scheme == "https":
            return self.https or self.http
        return self.http or self.https

    @property
    def route_name(self) -> str:
        endpoint = self.for_scheme("https")
        return endpoint.route_name if endpoint else "direct connection"


def parse_macos_proxy_settings(text: str) -> MacOSProxySettings:
    values: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"^\s*([A-Za-z]+)\s*:\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2)

    def endpoint(prefix: str) -> ProxyEndpoint | None:
        if values.get(f"{prefix}Enable") != "1":
            return None
        host = values.get(f"{prefix}Proxy", "").strip()
        try:
            port = int(values.get(f"{prefix}Port", "0"))
        except ValueError:
            return None
        if not host or not 1 <= port <= 65535:
            return None
        return ProxyEndpoint(prefix, host, port)

    return MacOSProxySettings(http=endpoint("HTTP"), https=endpoint("HTTPS"))


def read_macos_proxy_settings() -> MacOSProxySettings:
    if sys.platform != "darwin" or not os.path.isfile("/usr/sbin/scutil"):
        return MacOSProxySettings()
    try:
        result = subprocess.run(
            ["/usr/sbin/scutil", "--proxy"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return MacOSProxySettings()
    if result.returncode != 0:
        return MacOSProxySettings()
    return parse_macos_proxy_settings(result.stdout)


class ExplicitProxyHandler(urllib.request.ProxyHandler):
    """ProxyHandler variant that does not re-enter macOS proxy_bypass()."""

    def proxy_open(self, req: Any, proxy: str, proxy_type: str) -> Any:
        original_type = req.type
        parts = urlsplit(proxy)
        endpoint_type = parts.scheme or original_type
        host_port = parts.netloc or parts.path
        if not host_port:
            raise urllib.error.URLError("macOS system proxy endpoint is invalid")
        req.set_proxy(host_port, endpoint_type)
        if original_type == endpoint_type or original_type == "https":
            return None
        return self.parent.open(req, timeout=req.timeout)


class UpstreamTransport:
    def __init__(
        self,
        settings: MacOSProxySettings,
        connect_timeout: float,
        resolver: Any = socket.getaddrinfo,
    ):
        self.settings = settings
        self.connect_timeout = connect_timeout
        self.resolver = resolver
        proxies: dict[str, str] = {}
        if settings.http:
            proxies["http"] = settings.http.url
        https_endpoint = settings.for_scheme("https")
        if https_endpoint:
            proxies["https"] = https_endpoint.url
        self.direct_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.proxy_opener = urllib.request.build_opener(ExplicitProxyHandler(proxies))
        self.resolved: dict[tuple[str, int], float] = {}
        self.resolve_lock = threading.RLock()

    @property
    def route_name(self) -> str:
        return self.settings.route_name

    def route_for_url(self, url: str) -> tuple[Any, str, str, int]:
        parts = urlsplit(url)
        host = parts.hostname or ""
        port = parts.port or (443 if parts.scheme == "https" else 80)
        if host.lower() in LOOPBACK_HOSTS:
            return self.direct_opener, "direct loopback connection", host, port
        endpoint = self.settings.for_scheme(parts.scheme)
        if endpoint:
            return self.proxy_opener, endpoint.route_name, endpoint.host, endpoint.port
        return self.direct_opener, "direct connection", host, port

    def ensure_resolvable(self, host: str, port: int, route_name: str) -> None:
        cache_key = (host, port)
        with self.resolve_lock:
            if cache_key in self.resolved and time.monotonic() - self.resolved[cache_key] < 60:
                return
        result_queue: queue.Queue[Any] = queue.Queue(maxsize=1)

        def worker() -> None:
            try:
                self.resolver(host, port, type=socket.SOCK_STREAM)
                result_queue.put((True, None))
            except Exception as error:  # noqa: BLE001
                result_queue.put((False, error))

        threading.Thread(target=worker, daemon=True, name="deepseek-dns-check").start()
        try:
            success, error = result_queue.get(timeout=self.connect_timeout)
        except queue.Empty:
            raise RuntimeError(
                f"DeepSeek DNS resolution timed out after {self.connect_timeout:g}s via {route_name}"
            ) from None
        if not success:
            detail = str(error) if error else "unknown resolver error"
            raise RuntimeError(f"DeepSeek DNS resolution failed via {route_name}: {detail}")
        with self.resolve_lock:
            self.resolved[cache_key] = time.monotonic()

    @staticmethod
    def set_read_timeout(response: Any, timeout: float) -> None:
        fp = getattr(response, "fp", None)
        raw = getattr(fp, "raw", None)
        sock = getattr(raw, "_sock", None)
        if sock is not None:
            sock.settimeout(timeout)

    def open(self, request: urllib.request.Request, read_timeout: float) -> Any:
        opener, route_name, endpoint_host, endpoint_port = self.route_for_url(request.full_url)
        self.ensure_resolvable(endpoint_host, endpoint_port, route_name)
        try:
            response = opener.open(request, timeout=self.connect_timeout)
        except urllib.error.HTTPError:
            raise
        except urllib.error.URLError as error:
            reason = error.reason
            if isinstance(reason, (socket.timeout, TimeoutError)):
                raise RuntimeError(
                    f"DeepSeek connection timed out after {self.connect_timeout:g}s via {route_name}"
                ) from None
            raise RuntimeError(f"DeepSeek connection failed via {route_name}: {reason}") from None
        except (socket.timeout, TimeoutError):
            raise RuntimeError(
                f"DeepSeek connection timed out after {self.connect_timeout:g}s via {route_name}"
            ) from None
        except ssl.SSLError as error:
            raise RuntimeError(f"DeepSeek TLS negotiation failed via {route_name}: {error}") from None
        self.set_read_timeout(response, read_timeout)
        return response


class CredentialProvider:
    def __init__(self, keychain_service: str, profiles_file: str | Path | None = None):
        self.keychain_service = keychain_service
        self.profiles_file = Path(profiles_file).expanduser() if profiles_file else None

    @staticmethod
    def _mock_key() -> str:
        """Allow fake credentials only for the loopback upstream test harness."""
        upstream = urlsplit(os.environ.get("DEEPSEEK_UPSTREAM_URL", ""))
        if (upstream.hostname or "").lower() not in LOOPBACK_HOSTS:
            return ""
        return os.environ.get("CODEX_SWITCHER_MOCK_API_KEY", "").strip()

    def _keychain_result(self, account: str | None, *, password: bool) -> subprocess.CompletedProcess[str]:
        command = [
            "/usr/bin/security",
            "find-generic-password",
            "-s",
            self.keychain_service,
        ]
        if account is not None:
            command += ["-a", account]
        if password:
            command.append("-w")
        return subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE if password else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )

    def _exact_key_exists(self, _service: str, account: str) -> bool:
        try:
            return self._keychain_result(account, password=False).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def _legacy_service_exists(self, _service: str) -> bool:
        try:
            return self._keychain_result(None, password=False).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def _profile_context(self) -> tuple[dict[str, str], bool]:
        if self.profiles_file is None:
            return {"id": LEGACY_PROFILE_ID, "displayName": DEFAULT_PROFILE_NAME}, True
        state = load_state(self.profiles_file)
        state, migrated = migrated_state(
            "codex",
            state,
            self._exact_key_exists,
            self._legacy_service_exists,
        )
        profile = resolve_profile(state, str(state.get("activeProfileId") or ""))
        allow_legacy_service = migrated or (
            len(state["profiles"]) == 1 and profile["id"] == LEGACY_PROFILE_ID
        )
        return profile, allow_legacy_service

    def profile(self) -> dict[str, str]:
        return self._profile_context()[0]

    def status(self) -> dict[str, str]:
        if self._mock_key():
            return {
                "id": "environment",
                "name": "Environment override",
                "key": "present",
                "valid": "yes",
                "reason": "",
            }
        try:
            profile, allow_legacy_service = self._profile_context()
            present = self._exact_key_exists(self.keychain_service, profile["id"])
            if not present and allow_legacy_service:
                present = self._legacy_service_exists(self.keychain_service)
            return {
                "id": profile["id"],
                "name": profile["displayName"],
                "key": "present" if present else "missing",
                "valid": "yes" if present else "no",
                "reason": "" if present else f"Credential Profile {profile['displayName']} has no Keychain item",
            }
        except CredentialProfileError as exc:
            return {"id": "", "name": "", "key": "missing", "valid": "no", "reason": str(exc)}

    def get(self) -> str:
        environment_key = self._mock_key()
        if environment_key:
            return environment_key
        profile, allow_legacy_service = self._profile_context()
        result = self._keychain_result(profile["id"], password=True)
        if result.returncode != 0 and allow_legacy_service:
            result = self._keychain_result(None, password=True)
        key = result.stdout.strip()
        if result.returncode != 0 or not key:
            raise RuntimeError(
                f"Credential Profile '{profile['displayName']}' ({profile['id']}) has no Keychain item"
            )
        return key

    def exists(self) -> bool:
        try:
            return bool(self.get())
        except (OSError, subprocess.SubprocessError, RuntimeError):
            return False


class PendingToolCalls:
    """Keeps complete DeepSeek tool-call turns for every later replay."""

    def __init__(self, limit: int = 512):
        self.limit = limit
        self.lock = threading.RLock()
        self.turns: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self.call_to_turn: dict[str, str] = {}

    def remember(self, assistant_message: dict[str, Any]) -> None:
        tool_calls = assistant_message.get("tool_calls") or []
        if not tool_calls:
            return
        if "reasoning_content" not in assistant_message:
            raise RuntimeError("DeepSeek tool-call response omitted reasoning_content")
        turn_id = new_id("turn")
        replay_message = {
            "role": "assistant",
            "content": copy.deepcopy(assistant_message.get("content")),
            "reasoning_content": copy.deepcopy(assistant_message.get("reasoning_content")),
            "tool_calls": copy.deepcopy(tool_calls),
        }
        with self.lock:
            for call in replay_message["tool_calls"]:
                call_id = str(call.get("id") or new_id("call"))
                call["id"] = call_id
                self.call_to_turn[call_id] = turn_id
            self.turns[turn_id] = replay_message
            self.turns.move_to_end(turn_id)
            while len(self.turns) > self.limit:
                evicted_turn_id, evicted_message = self.turns.popitem(last=False)
                for call in evicted_message.get("tool_calls") or []:
                    call_id = str(call.get("id") or "")
                    if self.call_to_turn.get(call_id) == evicted_turn_id:
                        self.call_to_turn.pop(call_id, None)

    def get(self, call_id: str) -> tuple[str, dict[str, Any]] | None:
        with self.lock:
            turn_id = self.call_to_turn.get(call_id)
            message = self.turns.get(turn_id) if turn_id else None
            if not turn_id or not message:
                return None
            self.turns.move_to_end(turn_id)
            return turn_id, copy.deepcopy(message)


class DeepSeekAdapter:
    def __init__(self, config: ProxyConfig, credentials: CredentialProvider):
        self.config = config
        self.credentials = credentials
        self.pending = PendingToolCalls()
        self.transport = UpstreamTransport(read_macos_proxy_settings(), config.connect_timeout)
        self.last_codex_reasoning_effort: str | None = None
        self.last_upstream_reasoning_effort: str | None = None
        self.last_reasoning_effort_translation: str | None = None

    def convert_tools(
        self, body: dict[str, Any]
    ) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, str]]:
        original_tools = [tool for tool in body.get("tools", []) if isinstance(tool, dict)]
        original_tools = select_tools(original_tools, body)
        chat_tools: list[dict[str, Any]] = []
        safe_to_original: dict[str, str] = {}
        original_types: dict[str, str] = {}
        for tool in original_tools:
            function = tool.get("function") if isinstance(tool.get("function"), dict) else tool
            original_name = str(function.get("name") or tool.get("name") or "")
            if not original_name:
                continue
            safe_name = safe_tool_name(original_name)
            safe_to_original[safe_name] = original_name
            original_types[original_name] = str(tool.get("type") or "function")
            parameters = function.get("parameters") or tool.get("parameters")
            if not isinstance(parameters, dict):
                parameters = {
                    "type": "object",
                    "properties": {"input": {"type": "string"}},
                    "required": ["input"],
                }
            chat_tools.append(
                {
                    "type": "function",
                    "function": {
                        "name": safe_name,
                        "description": str(function.get("description") or tool.get("description") or ""),
                        "parameters": parameters,
                    },
                }
            )
        return chat_tools, safe_to_original, original_types

    def convert_tool_choice(self, choice: Any) -> Any:
        if isinstance(choice, str):
            return choice if choice in {"auto", "none", "required"} else "auto"
        if isinstance(choice, dict):
            name = choice.get("name") or choice.get("function", {}).get("name")
            if name:
                return {"type": "function", "function": {"name": safe_tool_name(str(name))}}
        return "auto"

    def convert_messages(self, body: dict[str, Any]) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        system_chunks: list[str] = []
        emitted_pending_turns: set[str] = set()
        queued_calls: list[dict[str, Any]] = []
        queued_reasoning: Any = None
        queued_reasoning_present = False
        queued_content: Any = ""
        queued_pending_turns: set[str] = set()

        instructions = content_text(body.get("instructions"))
        if instructions:
            system_chunks.append(instructions)

        def flush_calls() -> None:
            nonlocal queued_calls, queued_reasoning, queued_reasoning_present, queued_content, queued_pending_turns
            if not queued_calls:
                return
            assistant: dict[str, Any] = {
                "role": "assistant",
                "content": queued_content,
                "tool_calls": queued_calls,
            }
            if queued_reasoning_present:
                assistant["reasoning_content"] = queued_reasoning
            messages.append(assistant)
            emitted_pending_turns.update(queued_pending_turns)
            queued_calls = []
            queued_reasoning = None
            queued_reasoning_present = False
            queued_content = ""
            queued_pending_turns = set()

        input_value = body.get("input", "")
        if isinstance(input_value, str):
            if input_value:
                messages.append({"role": "user", "content": input_value})
        elif isinstance(input_value, list):
            for item in input_value:
                if isinstance(item, str):
                    flush_calls()
                    messages.append({"role": "user", "content": item})
                    continue
                if not isinstance(item, dict):
                    continue
                item_type = str(item.get("type") or "")
                role = str(item.get("role") or "")
                if item_type == "message" or role:
                    flush_calls()
                    text = content_text(item.get("content"))
                    if role in {"developer", "system"}:
                        if text:
                            system_chunks.append(text)
                    elif role in {"user", "assistant"}:
                        messages.append({"role": role, "content": text})
                    continue
                if item_type in {"function_call", "custom_tool_call"}:
                    call_id = str(item.get("call_id") or item.get("id") or new_id("call"))
                    name = str(item.get("name") or "")
                    arguments = item.get("arguments", item.get("input", "{}"))
                    if not isinstance(arguments, str):
                        arguments = compact_json(arguments)
                    if item_type == "custom_tool_call":
                        arguments = compact_json({"input": arguments})
                    pending = self.pending.get(call_id)
                    if pending:
                        _, assistant = pending
                        if queued_pending_turns and pending[0] not in queued_pending_turns:
                            flush_calls()
                        queued_pending_turns.add(pending[0])
                        if "reasoning_content" in assistant:
                            queued_reasoning = copy.deepcopy(assistant.get("reasoning_content"))
                            queued_reasoning_present = True
                        queued_content = copy.deepcopy(assistant.get("content"))
                    queued_calls.append(
                        {
                            "id": call_id,
                            "type": "function",
                            "function": {
                                "name": safe_tool_name(name),
                                "arguments": arguments or "{}",
                            },
                        }
                    )
                    continue
                if item_type in {"function_call_output", "custom_tool_call_output"}:
                    call_id = str(item.get("call_id") or item.get("id") or "")
                    flush_calls()
                    pending = self.pending.get(call_id) if call_id else None
                    if pending and pending[0] not in emitted_pending_turns:
                        messages.append(pending[1])
                        emitted_pending_turns.add(pending[0])
                    if call_id:
                        messages.append(
                            {"role": "tool", "tool_call_id": call_id, "content": content_text(item.get("output"))}
                        )
                    continue
                text = content_text(item.get("content", item))
                if text:
                    flush_calls()
                    messages.append({"role": "user", "content": text})
            flush_calls()

        if system_chunks:
            messages.insert(0, {"role": "system", "content": "\n\n".join(system_chunks)})
        return messages

    def payload(self, body: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str], dict[str, str]]:
        messages = self.convert_messages(body)
        tools, safe_to_original, original_types = self.convert_tools(body)
        stream = body.get("stream", True) is not False
        payload: dict[str, Any] = {
            "model": str(body.get("model") or "deepseek-v4-pro"),
            "messages": messages,
            "stream": stream,
            "thinking": {"type": self.config.thinking},
        }
        if stream:
            payload["stream_options"] = {"include_usage": True}
        if self.config.thinking == "enabled":
            requested_effort = body.get("reasoning", {}).get("effort") if isinstance(body.get("reasoning"), dict) else None
            requested_text = str(requested_effort) if requested_effort is not None else None
            upstream_effort = upstream_effort_for(requested_text)
            payload["reasoning_effort"] = upstream_effort
            self.last_codex_reasoning_effort = requested_text
            self.last_upstream_reasoning_effort = upstream_effort
            self.last_reasoning_effort_translation = (
                f"{requested_text}->{upstream_effort}" if requested_text is not None else f"default->{upstream_effort}"
            )
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = self.convert_tool_choice(body.get("tool_choice", "auto"))
        max_tokens = body.get("max_output_tokens")
        if isinstance(max_tokens, int) and max_tokens > 0:
            payload["max_tokens"] = max_tokens
        for key in ("temperature", "top_p"):
            if isinstance(body.get(key), (int, float)):
                payload[key] = body[key]
        return payload, safe_to_original, original_types

    @staticmethod
    def read_stream(response: Any) -> dict[str, Any]:
        metadata: dict[str, Any] = {}
        usage: dict[str, Any] = {}
        content_chunks: list[str] = []
        reasoning_chunks: list[str] = []
        content_seen = False
        reasoning_seen = False
        finish_reason: Any = None
        tool_calls: dict[int, dict[str, Any]] = {}
        saw_chunk = False

        for raw_line in response:
            line = raw_line.decode("utf-8", "replace").strip()
            if not line or line.startswith(":") or not line.startswith("data:"):
                continue
            payload_text = line[5:].strip()
            if payload_text == "[DONE]":
                break
            try:
                chunk = json.loads(payload_text)
            except json.JSONDecodeError:
                raise RuntimeError("DeepSeek returned an invalid streaming JSON chunk") from None
            if not isinstance(chunk, dict):
                continue
            saw_chunk = True
            for key in ("id", "created", "model", "system_fingerprint"):
                if key in chunk and key not in metadata:
                    metadata[key] = chunk[key]
            if isinstance(chunk.get("usage"), dict):
                usage = chunk["usage"]
            choices = chunk.get("choices") or []
            if not choices or not isinstance(choices[0], dict):
                continue
            choice = choices[0]
            if choice.get("finish_reason") is not None:
                finish_reason = choice.get("finish_reason")
            delta = choice.get("delta") or {}
            if not isinstance(delta, dict):
                continue
            if "reasoning_content" in delta:
                reasoning_seen = True
                value = delta.get("reasoning_content")
                if value is not None:
                    reasoning_chunks.append(str(value))
            if "content" in delta:
                content_seen = True
                value = delta.get("content")
                if value is not None:
                    content_chunks.append(str(value))
            for fallback_index, call_delta in enumerate(delta.get("tool_calls") or []):
                if not isinstance(call_delta, dict):
                    continue
                try:
                    call_index = int(call_delta.get("index", fallback_index))
                except (TypeError, ValueError):
                    call_index = fallback_index
                call = tool_calls.setdefault(
                    call_index,
                    {"id": "", "type": "function", "function": {"name": "", "arguments": ""}},
                )
                if call_delta.get("id"):
                    call["id"] = str(call_delta["id"])
                if call_delta.get("type"):
                    call["type"] = str(call_delta["type"])
                function_delta = call_delta.get("function") or {}
                if isinstance(function_delta, dict):
                    if function_delta.get("name") is not None:
                        call["function"]["name"] += str(function_delta.get("name") or "")
                    if function_delta.get("arguments") is not None:
                        call["function"]["arguments"] += str(function_delta.get("arguments") or "")

        if not saw_chunk:
            raise RuntimeError("DeepSeek returned an empty streaming response")
        message: dict[str, Any] = {
            "role": "assistant",
            "content": "".join(content_chunks) if content_seen else None,
        }
        if reasoning_seen:
            message["reasoning_content"] = "".join(reasoning_chunks)
        if tool_calls:
            message["tool_calls"] = [tool_calls[index] for index in sorted(tool_calls)]
        return {
            **metadata,
            "object": "chat.completion",
            "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
            "usage": usage,
        }

    def call(self, body: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str], dict[str, str]]:
        payload, safe_to_original, original_types = self.payload(body)
        request = urllib.request.Request(
            self.config.upstream_url,
            data=compact_json(payload).encode("utf-8"),
            headers={
                "content-type": "application/json",
                "authorization": f"Bearer {self.credentials.get()}",
                "user-agent": f"codex-deepseek-local-proxy/{VERSION}",
            },
            method="POST",
        )
        try:
            read_timeout = (
                self.config.stream_idle_timeout if payload.get("stream") else self.config.response_timeout
            )
            with self.transport.open(request, read_timeout=read_timeout) as response:
                content_type = str(response.headers.get("content-type") or "").lower()
                if "text/event-stream" in content_type:
                    data = self.read_stream(response)
                else:
                    raw = response.read().decode("utf-8", "replace")
                    try:
                        data = json.loads(raw)
                    except json.JSONDecodeError:
                        raise RuntimeError("DeepSeek returned an invalid JSON response") from None
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", "replace")
            try:
                detail = json.loads(raw).get("error", {}).get("message")
            except (json.JSONDecodeError, AttributeError):
                detail = raw[:500]
            raise RuntimeError(f"DeepSeek HTTP {error.code}: {detail or 'request failed'}") from None
        except (socket.timeout, TimeoutError):
            if payload.get("stream"):
                raise RuntimeError(
                    f"DeepSeek model stream was idle for {self.config.stream_idle_timeout:g}s"
                ) from None
            raise RuntimeError(
                f"DeepSeek model response timed out after {self.config.response_timeout:g}s"
            ) from None
        except ssl.SSLError as error:
            raise RuntimeError(f"DeepSeek TLS stream failed: {error}") from None
        message = ((data.get("choices") or [{}])[0].get("message") or {})
        tool_calls = message.get("tool_calls") or []
        for call in tool_calls:
            if not call.get("id"):
                call["id"] = new_id("call")
        if tool_calls:
            self.pending.remember(message)
        return data, safe_to_original, original_types

    def check_upstream(self) -> dict[str, Any]:
        parts = urlsplit(self.config.upstream_url)
        models_url = urlunsplit((parts.scheme, parts.netloc, "/models", "", ""))
        request = urllib.request.Request(
            models_url,
            headers={
                "authorization": f"Bearer {self.credentials.get()}",
                "user-agent": f"codex-deepseek-local-proxy/{VERSION}",
            },
            method="GET",
        )
        started = time.monotonic()
        try:
            with self.transport.open(request, read_timeout=self.config.health_read_timeout) as response:
                data = json.loads(response.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"DeepSeek credential check failed with HTTP {error.code}") from None
        except (socket.timeout, TimeoutError):
            raise RuntimeError(
                f"DeepSeek models response timed out after {self.config.health_read_timeout:g}s"
            ) from None
        except ssl.SSLError as error:
            raise RuntimeError(f"DeepSeek models TLS read failed: {error}") from None
        except json.JSONDecodeError:
            raise RuntimeError("DeepSeek models endpoint returned invalid JSON") from None
        model_ids = sorted(
            str(model.get("id")) for model in data.get("data", [])
            if isinstance(model, dict) and model.get("id")
        )
        if "deepseek-v4-pro" not in model_ids:
            raise RuntimeError("DeepSeek V4 Pro is not available for this API key")
        return {
            "status": "ok",
            "models": model_ids,
            "elapsed_ms": int((time.monotonic() - started) * 1000),
            "network_route": self.transport.route_name,
            "thinking": self.config.thinking,
            "reasoning_effort": "dynamic",
            "codex_reasoning_effort": "high|xhigh",
            "upstream_reasoning_effort": "dynamic",
            "accepted_codex_reasoning_efforts": ACCEPTED_CODEX_EFFORTS,
            "reasoning_effort_mapping": CODEX_EFFORT_TO_UPSTREAM,
            "last_request_codex_reasoning_effort": self.last_codex_reasoning_effort,
            "last_request_upstream_reasoning_effort": self.last_upstream_reasoning_effort,
            "last_request_reasoning_effort_translation": self.last_reasoning_effort_translation,
        }


def response_base(body: dict[str, Any], response_id: str, status: str = "in_progress") -> dict[str, Any]:
    return {
        "id": response_id,
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "error": None,
        "incomplete_details": None,
        "model": str(body.get("model") or "deepseek-v4-pro"),
        "output": [],
        "parallel_tool_calls": bool(body.get("parallel_tool_calls", False)),
        "tool_choice": body.get("tool_choice", "auto"),
    }


def output_items(
    data: dict[str, Any], safe_to_original: dict[str, str], original_types: dict[str, str]
) -> list[dict[str, Any]]:
    message = ((data.get("choices") or [{}])[0].get("message") or {})
    items: list[dict[str, Any]] = []
    content = str(message.get("content") or "")
    # Chat Completions keeps pre-tool content on the same assistant message as
    # tool_calls. The Responses wire format has no equivalent combined item;
    # replay it from PendingToolCalls instead of emitting a second assistant
    # message that Codex would later place before the function_call item.
    if not message.get("tool_calls"):
        items.append(
            {
                "id": new_id("msg"),
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": content, "annotations": []}],
            }
        )
    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        safe_name = str(function.get("name") or "")
        original_name = safe_to_original.get(safe_name, safe_name)
        call_id = str(call.get("id") or new_id("call"))
        arguments = function.get("arguments") or "{}"
        if not isinstance(arguments, str):
            arguments = compact_json(arguments)
        if original_types.get(original_name) == "custom":
            try:
                parsed = json.loads(arguments)
                custom_input = parsed.get("input", arguments) if isinstance(parsed, dict) else arguments
            except json.JSONDecodeError:
                custom_input = arguments
            items.append(
                {
                    "id": new_id("ctc"),
                    "type": "custom_tool_call",
                    "status": "completed",
                    "call_id": call_id,
                    "name": original_name,
                    "input": str(custom_input),
                }
            )
        else:
            items.append(
                {
                    "id": new_id("fc"),
                    "type": "function_call",
                    "status": "completed",
                    "call_id": call_id,
                    "name": original_name,
                    "arguments": arguments,
                }
            )
    return items


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "CodexDeepSeekProxy/1.0"
    protocol_version = "HTTP/1.1"

    @property
    def app(self) -> "ProxyServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[proxy] " + (fmt % args) + "\n")

    def send_json(self, status: int, value: Any) -> None:
        data = compact_json(value).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_event(self, event: str, value: Any) -> None:
        payload = f"event: {event}\ndata: {compact_json(value)}\n\n".encode("utf-8")
        self.wfile.write(payload)
        self.wfile.flush()

    def authorized(self) -> bool:
        expected = self.app.config.local_token
        if not expected:
            return True
        supplied = self.headers.get("authorization", "")
        return hmac.compare_digest(supplied, f"Bearer {expected}")

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in {"/health", "/v1/health"}:
            credential = self.app.credentials.status()
            self.send_json(
                200,
                {
                    "status": "ok",
                    "version": VERSION,
                    "thinking": self.app.config.thinking,
                    "reasoning_effort": "dynamic",
                    "codex_reasoning_effort": "high|xhigh",
                    "upstream_reasoning_effort": "dynamic",
                    "accepted_codex_reasoning_efforts": ACCEPTED_CODEX_EFFORTS,
                    "reasoning_effort_mapping": CODEX_EFFORT_TO_UPSTREAM,
                    "last_request_codex_reasoning_effort": self.app.adapter.last_codex_reasoning_effort,
                    "last_request_upstream_reasoning_effort": self.app.adapter.last_upstream_reasoning_effort,
                    "last_request_reasoning_effort_translation": self.app.adapter.last_reasoning_effort_translation,
                    "network_route": self.app.adapter.transport.route_name,
                    "connect_timeout_seconds": self.app.config.connect_timeout,
                    "stream_idle_timeout_seconds": self.app.config.stream_idle_timeout,
                    "credential_profile_id": credential["id"],
                    "credential_profile_name": credential["name"],
                    "credential_key_present": credential["key"] == "present",
                    "credential_profile_valid": credential["valid"] == "yes",
                    "credential_profile_reason": credential["reason"],
                },
            )
            return
        if path in {"/models", "/v1/models"}:
            models = [
                {"id": "deepseek-v4-pro", "object": "model", "owned_by": "deepseek"},
                {"id": "deepseek-v4-flash", "object": "model", "owned_by": "deepseek"},
            ]
            self.send_json(200, {"object": "list", "data": models})
            return
        if path in {"/upstream-health", "/v1/upstream-health"}:
            if not self.authorized():
                self.send_json(401, {"error": {"message": "Invalid local proxy token"}})
                return
            try:
                self.send_json(200, self.app.adapter.check_upstream())
            except Exception as error:  # noqa: BLE001
                self.send_json(502, {"status": "error", "error": {"message": str(error)}})
            return
        self.send_json(404, {"error": {"message": f"No route for GET {self.path}"}})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/")
        if path not in {"/responses", "/v1/responses"}:
            self.send_json(404, {"error": {"message": f"No route for POST {self.path}"}})
            return
        if not self.authorized():
            self.send_json(401, {"error": {"message": "Invalid local proxy token"}})
            return
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(400, {"error": {"message": "Invalid request size"}})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_json(400, {"error": {"message": "Invalid JSON"}})
            return
        if not isinstance(body, dict):
            self.send_json(400, {"error": {"message": "Request body must be an object"}})
            return
        if body.get("stream", True) is False:
            self.handle_non_stream(body)
        else:
            self.handle_stream(body)

    def handle_non_stream(self, body: dict[str, Any]) -> None:
        try:
            data, name_map, type_map = self.app.adapter.call(body)
            items = output_items(data, name_map, type_map)
            response_id = new_id("resp")
            response = response_base(body, response_id, "completed")
            response["output"] = items
            response["usage"] = self.usage(data)
            self.send_json(200, response)
        except Exception as error:  # noqa: BLE001
            self.send_json(502, {"error": {"message": str(error)}})

    def handle_stream(self, body: dict[str, Any]) -> None:
        response_id = new_id("resp")
        base = response_base(body, response_id)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache, no-store")
        self.send_header("connection", "close")
        self.send_header("x-accel-buffering", "no")
        self.end_headers()
        try:
            self.send_event("response.created", {"type": "response.created", "response": base})
            self.send_event("response.in_progress", {"type": "response.in_progress", "response": base})
            result_queue: queue.Queue[Any] = queue.Queue(maxsize=1)

            def worker() -> None:
                try:
                    result_queue.put((True, self.app.adapter.call(body)))
                except Exception as error:  # noqa: BLE001
                    result_queue.put((False, error))

            threading.Thread(target=worker, daemon=True, name="deepseek-upstream").start()
            while True:
                try:
                    success, result = result_queue.get(timeout=5)
                    break
                except queue.Empty:
                    self.wfile.write(f": keep-alive {int(time.time())}\n\n".encode("ascii"))
                    self.wfile.flush()
            if not success:
                raise result
            data, name_map, type_map = result
            items = output_items(data, name_map, type_map)
            for output_index, item in enumerate(items):
                if item["type"] == "message":
                    self.emit_message(output_index, item)
                elif item["type"] == "custom_tool_call":
                    self.emit_custom_call(output_index, item)
                else:
                    self.emit_function_call(output_index, item)
            completed = response_base(body, response_id, "completed")
            completed["output"] = items
            completed["usage"] = self.usage(data)
            self.send_event("response.completed", {"type": "response.completed", "response": completed})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as error:  # noqa: BLE001
            failed = response_base(body, response_id, "failed")
            failed["error"] = {"code": "upstream_error", "message": str(error)}
            try:
                self.send_event("response.failed", {"type": "response.failed", "response": failed})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    def emit_message(self, index: int, item: dict[str, Any]) -> None:
        text = item["content"][0]["text"]
        pending = {**item, "status": "in_progress", "content": []}
        self.send_event("response.output_item.added", {"type": "response.output_item.added", "output_index": index, "item": pending})
        part = {"type": "output_text", "text": "", "annotations": []}
        common = {"item_id": item["id"], "output_index": index, "content_index": 0}
        self.send_event("response.content_part.added", {"type": "response.content_part.added", **common, "part": part})
        if text:
            self.send_event("response.output_text.delta", {"type": "response.output_text.delta", **common, "delta": text})
        self.send_event("response.output_text.done", {"type": "response.output_text.done", **common, "text": text})
        done_part = {"type": "output_text", "text": text, "annotations": []}
        self.send_event("response.content_part.done", {"type": "response.content_part.done", **common, "part": done_part})
        self.send_event("response.output_item.done", {"type": "response.output_item.done", "output_index": index, "item": item})

    def emit_function_call(self, index: int, item: dict[str, Any]) -> None:
        arguments = item["arguments"]
        pending = {**item, "status": "in_progress", "arguments": ""}
        common = {"item_id": item["id"], "output_index": index}
        self.send_event("response.output_item.added", {"type": "response.output_item.added", "output_index": index, "item": pending})
        self.send_event("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", **common, "delta": arguments})
        self.send_event("response.function_call_arguments.done", {"type": "response.function_call_arguments.done", **common, "arguments": arguments})
        self.send_event("response.output_item.done", {"type": "response.output_item.done", "output_index": index, "item": item})

    def emit_custom_call(self, index: int, item: dict[str, Any]) -> None:
        custom_input = item["input"]
        pending = {**item, "status": "in_progress", "input": ""}
        common = {"item_id": item["id"], "output_index": index}
        self.send_event("response.output_item.added", {"type": "response.output_item.added", "output_index": index, "item": pending})
        self.send_event("response.custom_tool_call_input.delta", {"type": "response.custom_tool_call_input.delta", **common, "delta": custom_input})
        self.send_event("response.custom_tool_call_input.done", {"type": "response.custom_tool_call_input.done", **common, "input": custom_input})
        self.send_event("response.output_item.done", {"type": "response.output_item.done", "output_index": index, "item": item})

    @staticmethod
    def usage(data: dict[str, Any]) -> dict[str, int]:
        usage = data.get("usage") or {}
        return {
            "input_tokens": int(usage.get("prompt_tokens") or 0),
            "output_tokens": int(usage.get("completion_tokens") or 0),
            "total_tokens": int(usage.get("total_tokens") or 0),
        }


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, config: ProxyConfig):
        self.config = config
        self.credentials = CredentialProvider(
            config.keychain_service, config.credential_profiles_file or None
        )
        self.adapter = DeepSeekAdapter(config, self.credentials)
        super().__init__((config.host, config.port), ProxyHandler)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("CODEX_DEEPSEEK_PROXY_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CODEX_DEEPSEEK_PROXY_PORT", DEFAULT_PORT)))
    parser.add_argument("--upstream-url", default=os.environ.get("DEEPSEEK_UPSTREAM_URL", DEFAULT_UPSTREAM))
    parser.add_argument("--keychain-service", default=os.environ.get("DEEPSEEK_KEYCHAIN_SERVICE", DEFAULT_KEYCHAIN_SERVICE))
    parser.add_argument(
        "--credential-profiles-file",
        default=os.environ.get(
            "DEEPSEEK_CREDENTIAL_PROFILES_FILE",
            str(Path.home() / ".codex/deepseek-credential-profiles.json"),
        ),
    )
    parser.add_argument("--local-token", default=os.environ.get("CODEX_DEEPSEEK_LOCAL_TOKEN", DEFAULT_LOCAL_TOKEN))
    parser.add_argument("--thinking", choices=("enabled", "disabled"), default=os.environ.get("DEEPSEEK_THINKING", "enabled"))
    parser.add_argument(
        "--connect-timeout",
        type=float,
        default=float(os.environ.get("DEEPSEEK_CONNECT_TIMEOUT", "8")),
    )
    parser.add_argument(
        "--stream-idle-timeout",
        type=float,
        default=float(os.environ.get("DEEPSEEK_STREAM_IDLE_TIMEOUT", "180")),
    )
    parser.add_argument(
        "--response-timeout",
        type=float,
        default=float(os.environ.get("DEEPSEEK_RESPONSE_TIMEOUT", "300")),
    )
    parser.add_argument(
        "--health-read-timeout",
        type=float,
        default=float(os.environ.get("DEEPSEEK_HEALTH_READ_TIMEOUT", "15")),
    )
    parser.add_argument("--check-config", action="store_true", help="Validate local configuration without starting the server")
    parser.add_argument("--version", action="version", version=VERSION)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.host not in {"127.0.0.1", "::1", "localhost"}:
        print("Refusing to bind the credentialed proxy outside loopback", file=sys.stderr)
        return 2
    if min(
        args.connect_timeout,
        args.stream_idle_timeout,
        args.response_timeout,
        args.health_read_timeout,
    ) <= 0:
        print("All timeout values must be greater than zero", file=sys.stderr)
        return 2
    config = ProxyConfig(
        host=args.host,
        port=args.port,
        upstream_url=args.upstream_url,
        keychain_service=args.keychain_service,
        local_token=args.local_token,
        thinking=args.thinking,
        connect_timeout=args.connect_timeout,
        stream_idle_timeout=args.stream_idle_timeout,
        response_timeout=args.response_timeout,
        health_read_timeout=args.health_read_timeout,
        credential_profiles_file=args.credential_profiles_file,
    )
    credentials = CredentialProvider(
        config.keychain_service, config.credential_profiles_file or None
    )
    if args.check_config:
        credential = credentials.status()
        if credential["valid"] != "yes":
            print(
                credential["reason"]
                or f"Missing Keychain item: {config.keychain_service}",
                file=sys.stderr,
            )
            return 1
        print("configuration=ok")
        return 0
    server = ProxyServer(config)
    print(
        f"codex-deepseek-proxy {VERSION} listening on http://{config.host}:{config.port} "
        f"(thinking={config.thinking}, reasoning_effort=dynamic, "
        f"network={server.adapter.transport.route_name}, connect_timeout={config.connect_timeout:g}s, "
        f"stream_idle_timeout={config.stream_idle_timeout:g}s)",
        file=sys.stderr,
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
