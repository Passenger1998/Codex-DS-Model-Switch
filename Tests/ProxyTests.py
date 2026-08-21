#!/usr/bin/env python3
from __future__ import annotations

import json
import importlib.util
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import tempfile
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROXY = ROOT / "Support" / "deepseek_responses_proxy.py"
TOKEN = "codex-deepseek-local"
PROXY_SPEC = importlib.util.spec_from_file_location("deepseek_responses_proxy_test", PROXY)
assert PROXY_SPEC and PROXY_SPEC.loader
PROXY_MODULE = importlib.util.module_from_spec(PROXY_SPEC)
sys.modules[PROXY_SPEC.name] = PROXY_MODULE
PROXY_SPEC.loader.exec_module(PROXY_MODULE)


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


class MockDeepSeekHandler(BaseHTTPRequestHandler):
    requests: list[dict[str, Any]] = []

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        result = {
            "object": "list",
            "data": [
                {"id": "deepseek-v4-pro", "object": "model", "owned_by": "deepseek"},
                {"id": "deepseek-v4-flash", "object": "model", "owned_by": "deepseek"},
            ],
        }
        raw = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length))
        self.__class__.requests.append(body)
        messages = body.get("messages") or []
        tool_output_ids = {
            str(message.get("tool_call_id")) for message in messages if message.get("role") == "tool"
        }
        has_tool_output = bool(tool_output_ids)
        user_text = "\n".join(
            str(message.get("content") or "") for message in messages if message.get("role") == "user"
        )
        if "call_chain_2" in tool_output_ids:
            assistants = [message for message in messages if message.get("role") == "assistant" and message.get("tool_calls")]
            assert [message.get("reasoning_content") for message in assistants] == [
                "first-private-thinking",
                "second-private-thinking",
            ]
            assert [message.get("content") for message in assistants] == ["first preface", "second preface"]
            message = {"role": "assistant", "content": "multi tool loop complete"}
        elif "call_chain_1" in tool_output_ids:
            assistant = next(message for message in messages if message.get("role") == "assistant" and message.get("tool_calls"))
            assert assistant.get("reasoning_content") == "first-private-thinking"
            message = {
                "role": "assistant",
                "content": "second preface",
                "reasoning_content": "second-private-thinking",
                "tool_calls": [
                    {
                        "id": "call_chain_2",
                        "type": "function",
                        "function": {"name": body["tools"][0]["function"]["name"], "arguments": '{"stage":2}'},
                    }
                ],
            }
        elif has_tool_output:
            assistant = next(message for message in messages if message.get("role") == "assistant" and message.get("tool_calls"))
            assert assistant.get("reasoning_content") == "private-thinking"
            tool_text = "\n".join(str(message.get("content") or "") for message in messages if message.get("role") == "tool")
            message = {
                "role": "assistant",
                "content": "tool loop complete" if "CODEX_DEEPSEEK_TOOL_OK" in tool_text else "tool finished",
            }
        elif "E2E_TOOL" in user_text:
            tool = next(
                candidate for candidate in body.get("tools", [])
                if "exec" in candidate["function"]["name"] or "shell" in candidate["function"]["name"]
            )
            parameters = tool["function"].get("parameters") or {}
            properties = parameters.get("properties") or {}
            if "cmd" in properties:
                arguments = {"cmd": "printf CODEX_DEEPSEEK_TOOL_OK"}
            elif "command" in properties:
                arguments = {"command": "printf CODEX_DEEPSEEK_TOOL_OK"}
            elif "commands" in properties:
                arguments = {"commands": ["printf CODEX_DEEPSEEK_TOOL_OK"]}
            else:
                arguments = {"input": "printf CODEX_DEEPSEEK_TOOL_OK"}
            message = {
                "role": "assistant",
                "content": "",
                "reasoning_content": "private-thinking",
                "tool_calls": [
                    {
                        "id": "call_e2e_tool",
                        "type": "function",
                        "function": {"name": tool["function"]["name"], "arguments": json.dumps(arguments)},
                    }
                ],
            }
        elif "MULTI_TOOL_REPLAY" in user_text:
            tool_name = body["tools"][0]["function"]["name"]
            message = {
                "role": "assistant",
                "content": "first preface",
                "reasoning_content": "first-private-thinking",
                "tool_calls": [
                    {
                        "id": "call_chain_1",
                        "type": "function",
                        "function": {"name": tool_name, "arguments": '{"stage":1}'},
                    }
                ],
            }
        elif "call a tool" in user_text:
            tool_name = body["tools"][0]["function"]["name"]
            message = {
                "role": "assistant",
                "content": "checking the file",
                "reasoning_content": "private-thinking",
                "tool_calls": [
                    {
                        "id": "call_test_1",
                        "type": "function",
                        "function": {"name": tool_name, "arguments": '{"path":"README.md"}'},
                    }
                ],
            }
        else:
            message = {"role": "assistant", "content": "proxy ok"}
        if body.get("stream"):
            self.send_stream(message)
        else:
            result = {
                "id": "chat_test",
                "object": "chat.completion",
                "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
            }
            raw = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    def send_stream(self, message: dict[str, Any]) -> None:
        chunks: list[dict[str, Any]] = []

        def add(delta: dict[str, Any], finish_reason: str | None = None) -> None:
            chunks.append(
                {
                    "id": "chat_test",
                    "object": "chat.completion.chunk",
                    "model": "deepseek-v4-pro",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
                    "usage": None,
                }
            )

        reasoning = message.get("reasoning_content")
        if isinstance(reasoning, str):
            split = max(1, len(reasoning) // 3)
            for start in range(0, len(reasoning), split):
                add({"reasoning_content": reasoning[start:start + split]})
        content = message.get("content")
        if isinstance(content, str):
            split = max(1, len(content) // 2)
            for start in range(0, len(content), split):
                add({"content": content[start:start + split]})
        for index, call in enumerate(message.get("tool_calls") or []):
            function = call.get("function") or {}
            name = str(function.get("name") or "")
            arguments = str(function.get("arguments") or "")
            name_split = max(1, len(name) // 2)
            arguments_split = max(1, len(arguments) // 2)
            add(
                {
                    "tool_calls": [
                        {
                            "index": index,
                            "id": call.get("id"),
                            "type": "function",
                            "function": {
                                "name": name[:name_split],
                                "arguments": arguments[:arguments_split],
                            },
                        }
                    ]
                }
            )
            add(
                {
                    "tool_calls": [
                        {
                            "index": index,
                            "function": {
                                "name": name[name_split:],
                                "arguments": arguments[arguments_split:],
                            },
                        }
                    ]
                }
            )
        add({}, "tool_calls" if message.get("tool_calls") else "stop")
        chunks.append(
            {
                "id": "chat_test",
                "object": "chat.completion.chunk",
                "model": "deepseek-v4-pro",
                "choices": [],
                "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
            }
        )
        raw = b"".join(f"data: {json.dumps(chunk)}\n\n".encode() for chunk in chunks) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class ProxyIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), MockDeepSeekHandler)
        cls.upstream_thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.upstream_thread.start()
        cls.proxy_port = free_port()
        env = os.environ.copy()
        env["DEEPSEEK_API_KEY"] = "test-key-never-sent-to-the-internet"
        env["DEEPSEEK_UPSTREAM_URL"] = f"http://127.0.0.1:{cls.upstream.server_port}/chat/completions"
        cls.proxy = subprocess.Popen(
            [sys.executable, str(PROXY), "--port", str(cls.proxy_port), "--local-token", TOKEN],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
        )
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{cls.proxy_port}/health", timeout=0.5) as response:
                    if response.status == 200:
                        return
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        stderr = cls.proxy.stderr.read() if cls.proxy.stderr else ""
        raise RuntimeError(f"proxy did not start: {stderr}")

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.proxy.poll() is None:
            cls.proxy.send_signal(signal.SIGTERM)
            try:
                cls.proxy.wait(timeout=3)
            except subprocess.TimeoutExpired:
                cls.proxy.kill()
        if cls.proxy.stderr:
            cls.proxy.stderr.close()
        cls.upstream.shutdown()
        cls.upstream.server_close()

    def request(self, body: dict[str, Any], *, token: str = TOKEN) -> tuple[int, str]:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.proxy_port}/v1/responses",
            data=json.dumps(body).encode(),
            headers={"content-type": "application/json", "authorization": f"Bearer {token}"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            try:
                return error.code, error.read().decode()
            finally:
                error.close()

    def test_health_and_authentication(self) -> None:
        with urllib.request.urlopen(f"http://127.0.0.1:{self.proxy_port}/health", timeout=2) as response:
            health = json.load(response)
        self.assertEqual(health["status"], "ok")
        self.assertEqual(health["thinking"], "enabled")
        self.assertEqual(health["reasoning_effort"], "high")
        self.assertEqual(health["codex_reasoning_effort"], "high")
        self.assertEqual(health["upstream_reasoning_effort"], "high")
        self.assertEqual(health["accepted_codex_reasoning_efforts"], ["high"])
        self.assertIn(health["last_request_codex_reasoning_effort"], {None, "high"})
        self.assertIn(health["last_request_upstream_reasoning_effort"], {None, "high"})
        self.assertIn(health["last_request_reasoning_effort_translation"], {None, "high->high"})
        self.assertIn(health["network_route"], {"direct connection", "macOS HTTP system proxy", "macOS HTTPS system proxy"})
        status, text = self.request({"model": "deepseek-v4-pro", "input": "hello"}, token="wrong")
        self.assertEqual(status, 401)
        self.assertIn("Invalid local proxy token", text)
        upstream_request = urllib.request.Request(
            f"http://127.0.0.1:{self.proxy_port}/upstream-health",
            headers={"authorization": f"Bearer {TOKEN}"},
        )
        with urllib.request.urlopen(upstream_request, timeout=2) as response:
            upstream_health = json.load(response)
        self.assertEqual(upstream_health["status"], "ok")
        self.assertIn("deepseek-v4-pro", upstream_health["models"])
        self.assertEqual(upstream_health["reasoning_effort"], "high")
        self.assertEqual(upstream_health["codex_reasoning_effort"], "high")
        self.assertEqual(upstream_health["upstream_reasoning_effort"], "high")
        self.assertEqual(upstream_health["accepted_codex_reasoning_efforts"], ["high"])

    def test_macos_system_proxy_parsing_and_loopback_bypass(self) -> None:
        settings = PROXY_MODULE.parse_macos_proxy_settings(
            """
            <dictionary> {
              HTTPEnable : 1
              HTTPPort : 8080
              HTTPProxy : 127.0.0.1
              HTTPSEnable : 1
              HTTPSPort : 8443
              HTTPSProxy : proxy.example.test
            }
            """
        )
        self.assertEqual(settings.http.url, "http://127.0.0.1:8080")
        self.assertEqual(settings.https.url, "http://proxy.example.test:8443")
        transport = PROXY_MODULE.UpstreamTransport(settings, connect_timeout=0.5)
        _, upstream_route, upstream_host, upstream_port = transport.route_for_url(
            "https://api.deepseek.com/chat/completions"
        )
        _, local_route, local_host, local_port = transport.route_for_url("http://127.0.0.1:4878/health")
        self.assertEqual(upstream_route, "macOS HTTPS system proxy")
        self.assertEqual((upstream_host, upstream_port), ("proxy.example.test", 8443))
        self.assertEqual(local_route, "direct loopback connection")
        self.assertEqual((local_host, local_port), ("127.0.0.1", 4878))
        disabled = PROXY_MODULE.parse_macos_proxy_settings("HTTPEnable : 0\nHTTPSEnable : 0")
        self.assertEqual(disabled.route_name, "direct connection")

    def test_direct_dns_failure_has_a_separate_fast_timeout(self) -> None:
        def stalled_resolver(*_args: Any, **_kwargs: Any) -> None:
            time.sleep(1)

        transport = PROXY_MODULE.UpstreamTransport(
            PROXY_MODULE.MacOSProxySettings(),
            connect_timeout=0.05,
            resolver=stalled_resolver,
        )
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "DNS resolution timed out after 0.05s"):
            transport.ensure_resolvable("api.deepseek.invalid", 443, "direct connection")
        self.assertLess(time.monotonic() - started, 0.5)

    def test_proxy_connection_failure_is_fast_and_explicit(self) -> None:
        closed_port = free_port()
        settings = PROXY_MODULE.MacOSProxySettings(
            https=PROXY_MODULE.ProxyEndpoint("HTTPS", "127.0.0.1", closed_port)
        )
        transport = PROXY_MODULE.UpstreamTransport(settings, connect_timeout=0.2)
        request = urllib.request.Request("https://api.deepseek.com/models")
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "connection failed via macOS HTTPS system proxy"):
            transport.open(request, read_timeout=1)
        self.assertLess(time.monotonic() - started, 1)

    def test_proxy_effort_is_authoritative_and_mismatch_fails(self) -> None:
        config = PROXY_MODULE.ProxyConfig(
            host="127.0.0.1",
            port=4878,
            upstream_url="https://api.deepseek.com/chat/completions",
            keychain_service="test",
            local_token=TOKEN,
            thinking="enabled",
            reasoning_effort="max",
            connect_timeout=1,
            stream_idle_timeout=2,
            response_timeout=3,
            health_read_timeout=1,
        )
        adapter = PROXY_MODULE.DeepSeekAdapter(config, PROXY_MODULE.CredentialProvider("test"))
        payload, _, _ = adapter.payload(
            {"model": "deepseek-v4-pro", "stream": True, "reasoning": {"effort": "xhigh"}, "input": "hello"}
        )
        self.assertEqual(payload["thinking"], {"type": "enabled"})
        self.assertEqual(payload["reasoning_effort"], "max")
        self.assertEqual(adapter.last_codex_reasoning_effort, "xhigh")
        self.assertEqual(adapter.last_upstream_reasoning_effort, "max")
        self.assertEqual(adapter.last_reasoning_effort_translation, "xhigh->max")
        self.assertEqual(PROXY_MODULE.accepted_codex_efforts("max"), ["high", "xhigh"])
        self.assertEqual(PROXY_MODULE.accepted_codex_efforts("high"), ["high"])

        legacy_payload, _, _ = adapter.payload(
            {"model": "deepseek-v4-pro", "reasoning": {"effort": "high"}, "input": "legacy thread"}
        )
        self.assertEqual(legacy_payload["reasoning_effort"], "max")
        self.assertEqual(adapter.last_codex_reasoning_effort, "high")
        self.assertEqual(adapter.last_upstream_reasoning_effort, "max")
        self.assertEqual(adapter.last_reasoning_effort_translation, "high->max")

        high_config = PROXY_MODULE.ProxyConfig(**{**vars(config), "reasoning_effort": "high"})
        high_adapter = PROXY_MODULE.DeepSeekAdapter(high_config, PROXY_MODULE.CredentialProvider("test"))
        with self.assertRaisesRegex(RuntimeError, "Reasoning effort mismatch"):
            high_adapter.payload(
                {"model": "deepseek-v4-pro", "reasoning": {"effort": "xhigh"}, "input": "hello"}
            )

    def test_catalog_uses_codex_supported_effort_for_deepseek_max(self) -> None:
        catalog = json.loads((ROOT / "Support" / "deepseek.models.json").read_text(encoding="utf-8"))
        for model in catalog["models"]:
            efforts = [entry["effort"] for entry in model["supported_reasoning_levels"]]
            self.assertEqual(efforts, ["high", "xhigh"])

    def test_streaming_text_response(self) -> None:
        status, text = self.request(
            {
                "model": "deepseek-v4-pro",
                "stream": True,
                "instructions": "Be concise.",
                "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hello"}]}],
            }
        )
        self.assertEqual(status, 200)
        self.assertIn("event: response.created", text)
        self.assertIn("event: response.output_text.delta", text)
        self.assertIn("proxy ok", text)
        self.assertIn("event: response.completed", text)
        self.assertTrue(text.endswith("data: [DONE]\n\n"))
        upstream = MockDeepSeekHandler.requests[-1]
        self.assertEqual(upstream["model"], "deepseek-v4-pro")
        self.assertEqual(upstream["messages"][0], {"role": "system", "content": "Be concise."})
        self.assertEqual(upstream["thinking"], {"type": "enabled"})
        self.assertEqual(upstream["reasoning_effort"], "high")
        self.assertTrue(upstream["stream"])
        self.assertEqual(upstream["stream_options"], {"include_usage": True})

    def test_tool_call_and_reasoning_replay(self) -> None:
        long_name = "mcp__workspace__read_file_with_a_name_that_is_longer_than_sixty_four_characters"
        first_body = {
            "model": "deepseek-v4-pro",
            "stream": True,
            "input": [{"type": "message", "role": "user", "content": "call a tool"}],
            "tools": [
                {
                    "type": "function",
                    "name": long_name,
                    "description": "Read a workspace file",
                    "parameters": {"type": "object", "properties": {"path": {"type": "string"}}},
                }
            ],
        }
        status, first = self.request(first_body)
        self.assertEqual(status, 200)
        self.assertIn("response.function_call_arguments.done", first)
        self.assertIn(long_name, first)
        self.assertNotIn("private-thinking", first)

        second_body = {
            "model": "deepseek-v4-pro",
            "stream": True,
            "input": [
                {
                    "type": "function_call",
                    "call_id": "call_test_1",
                    "name": long_name,
                    "arguments": '{"path":"README.md"}',
                },
                {"type": "function_call_output", "call_id": "call_test_1", "output": "file contents"},
            ],
            "tools": first_body["tools"],
        }
        status, second = self.request(second_body)
        self.assertEqual(status, 200)
        self.assertIn("tool finished", second)
        upstream = MockDeepSeekHandler.requests[-1]
        assistants = [message for message in upstream["messages"] if message.get("role") == "assistant"]
        self.assertEqual(len(assistants), 1)
        assistant = assistants[0]
        self.assertEqual(assistant["reasoning_content"], "private-thinking")
        self.assertEqual(assistant["content"], "checking the file")
        self.assertEqual(upstream["messages"][-1]["role"], "tool")

        # DeepSeek requires tool-call reasoning in every later request, not only
        # the first request that returns that tool's output.
        third_body = {
            **second_body,
            "input": [
                *second_body["input"],
                {"type": "message", "role": "user", "content": "follow up after the tool"},
            ],
        }
        status, third = self.request(third_body)
        self.assertEqual(status, 200)
        self.assertIn("tool finished", third)
        upstream = MockDeepSeekHandler.requests[-1]
        assistant = next(message for message in upstream["messages"] if message.get("tool_calls"))
        self.assertEqual(assistant["reasoning_content"], "private-thinking")
        self.assertEqual(assistant["content"], "checking the file")

    def test_streaming_reasoning_survives_consecutive_tool_calls(self) -> None:
        tool = {
            "type": "function",
            "name": "test_stage",
            "description": "Run a numbered test stage",
            "parameters": {
                "type": "object",
                "properties": {"stage": {"type": "integer"}},
                "required": ["stage"],
            },
        }
        user = {"type": "message", "role": "user", "content": "MULTI_TOOL_REPLAY"}
        first_body = {"model": "deepseek-v4-pro", "stream": True, "input": [user], "tools": [tool]}
        status, first = self.request(first_body)
        self.assertEqual(status, 200)
        self.assertIn("call_chain_1", first)
        self.assertNotIn("first-private-thinking", first)
        self.assertNotIn("first preface", first)

        call_1 = {
            "type": "function_call",
            "call_id": "call_chain_1",
            "name": "test_stage",
            "arguments": '{"stage":1}',
        }
        output_1 = {"type": "function_call_output", "call_id": "call_chain_1", "output": "stage 1 done"}
        second_body = {
            "model": "deepseek-v4-pro",
            "stream": True,
            "input": [user, call_1, output_1],
            "tools": [tool],
        }
        status, second = self.request(second_body)
        self.assertEqual(status, 200)
        self.assertIn("call_chain_2", second)
        self.assertNotIn("second-private-thinking", second)

        call_2 = {
            "type": "function_call",
            "call_id": "call_chain_2",
            "name": "test_stage",
            "arguments": '{"stage":2}',
        }
        output_2 = {"type": "function_call_output", "call_id": "call_chain_2", "output": "stage 2 done"}
        third_body = {
            "model": "deepseek-v4-pro",
            "stream": True,
            "input": [user, call_1, output_1, call_2, output_2],
            "tools": [tool],
        }
        status, third = self.request(third_body)
        self.assertEqual(status, 200)
        self.assertIn("multi tool loop complete", third)
        self.assertNotIn("response.failed", third)
        upstream = MockDeepSeekHandler.requests[-1]
        assistants = [message for message in upstream["messages"] if message.get("tool_calls")]
        self.assertEqual(
            [(message["reasoning_content"], message["content"]) for message in assistants],
            [
                ("first-private-thinking", "first preface"),
                ("second-private-thinking", "second preface"),
            ],
        )

    def test_non_streaming_response(self) -> None:
        status, text = self.request({"model": "deepseek-v4-flash", "stream": False, "input": "hello"})
        self.assertEqual(status, 200)
        data = json.loads(text)
        self.assertEqual(data["status"], "completed")
        self.assertEqual(data["output"][0]["content"][0]["text"], "proxy ok")
        self.assertEqual(data["usage"]["total_tokens"], 10)

    def test_actual_codex_cli_end_to_end(self) -> None:
        codex_bin = Path(os.environ.get("CODEX_TEST_BIN", "/Applications/ChatGPT.app/Contents/Resources/codex"))
        if not codex_bin.is_file():
            self.skipTest("Codex CLI is not installed")
        with tempfile.TemporaryDirectory(prefix="codex-deepseek-e2e-") as temporary:
            codex_home = Path(temporary)
            catalog = codex_home / "deepseek.models.json"
            catalog.write_bytes((ROOT / "Support" / "deepseek.models.json").read_bytes())
            config = codex_home / "config.toml"
            config.write_text(
                f'''model = "deepseek-v4-pro"
model_provider = "deepseek_test"
model_reasoning_effort = "high"
model_catalog_json = "{catalog}"

[model_providers.deepseek_test]
name = "DeepSeek test proxy"
base_url = "http://127.0.0.1:{self.proxy_port}/v1"
wire_api = "responses"
supports_websockets = false
stream_idle_timeout_ms = 30000

[model_providers.deepseek_test.auth]
command = "/usr/bin/printf"
args = ["{TOKEN}"]
refresh_interval_ms = 0
''',
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["CODEX_HOME"] = str(codex_home)
            result = subprocess.run(
                [
                    str(codex_bin), "exec", "--ephemeral", "--skip-git-repo-check",
                    "--sandbox", "read-only", "--color", "never",
                    "E2E_TOOL: execute the requested harmless tool call, then return the provided final answer.",
                ],
                cwd=ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("CODEX_DEEPSEEK_TOOL_OK", result.stdout)
            self.assertIn("tool loop complete", result.stdout)
            upstream_tools = MockDeepSeekHandler.requests[-1].get("tools") or []
            self.assertTrue(upstream_tools, "Codex tools were not translated for DeepSeek")
            translated_names = {tool["function"]["name"] for tool in upstream_tools}
            self.assertTrue(any("exec" in name or "shell" in name for name in translated_names), translated_names)

    def test_actual_codex_cli_max_effort_end_to_end(self) -> None:
        codex_bin = Path(os.environ.get("CODEX_TEST_BIN", "/Applications/ChatGPT.app/Contents/Resources/codex"))
        if not codex_bin.is_file():
            self.skipTest("Codex CLI is not installed")

        max_proxy_port = free_port()
        proxy_env = os.environ.copy()
        proxy_env["DEEPSEEK_API_KEY"] = "test-key-never-sent-to-the-internet"
        proxy_env["DEEPSEEK_UPSTREAM_URL"] = f"http://127.0.0.1:{self.upstream.server_port}/chat/completions"
        max_proxy = subprocess.Popen(
            [
                sys.executable,
                str(PROXY),
                "--port", str(max_proxy_port),
                "--local-token", TOKEN,
                "--reasoning-effort", "max",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=proxy_env,
            text=True,
        )
        try:
            deadline = time.time() + 10
            while time.time() < deadline:
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{max_proxy_port}/health", timeout=0.5) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.05)
            else:
                stderr = max_proxy.stderr.read() if max_proxy.stderr else ""
                self.fail(f"max proxy did not start: {stderr}")

            request_start = len(MockDeepSeekHandler.requests)
            with tempfile.TemporaryDirectory(prefix="codex-deepseek-max-e2e-") as temporary:
                codex_home = Path(temporary)
                catalog = codex_home / "deepseek.models.json"
                catalog.write_bytes((ROOT / "Support" / "deepseek.models.json").read_bytes())
                config = codex_home / "config.toml"
                config.write_text(
                    f'''model = "deepseek-v4-pro"
model_provider = "deepseek_test"
model_reasoning_effort = "xhigh"
model_catalog_json = "{catalog}"

[model_providers.deepseek_test]
name = "DeepSeek test proxy max"
base_url = "http://127.0.0.1:{max_proxy_port}/v1"
wire_api = "responses"
supports_websockets = false
stream_idle_timeout_ms = 30000

[model_providers.deepseek_test.auth]
command = "/usr/bin/printf"
args = ["{TOKEN}"]
refresh_interval_ms = 0
''',
                    encoding="utf-8",
                )
                env = os.environ.copy()
                env["CODEX_HOME"] = str(codex_home)
                result = subprocess.run(
                    [
                        str(codex_bin), "exec", "--ephemeral", "--skip-git-repo-check",
                        "--sandbox", "read-only", "--color", "never",
                        "E2E_TOOL: execute the requested harmless tool call, then return the provided final answer.",
                    ],
                    cwd=ROOT,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("CODEX_DEEPSEEK_TOOL_OK", result.stdout)
                self.assertIn("tool loop complete", result.stdout)

            max_requests = MockDeepSeekHandler.requests[request_start:]
            self.assertGreaterEqual(len(max_requests), 2)
            self.assertTrue(all(request.get("reasoning_effort") == "max" for request in max_requests), max_requests)
        finally:
            if max_proxy.poll() is None:
                max_proxy.send_signal(signal.SIGTERM)
                try:
                    max_proxy.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    max_proxy.kill()
            if max_proxy.stderr:
                max_proxy.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
