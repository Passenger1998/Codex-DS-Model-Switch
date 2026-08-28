#!/usr/bin/env python3
"""Minimal mock Anthropic Messages API used for local end-to-end verification.

Logs the model name and auth headers of every request to a JSONL file, and
answers with a tiny fixed text completion.  Never contacts the real Anthropic
or DeepSeek APIs; total cost is zero.
"""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    log_path: Path | None = None
    lock = threading.Lock()

    def log_message(self, *_args: object) -> None:
        return

    def _record(self, payload: dict) -> None:
        if self.log_path is None:
            return
        with self.lock:
            with self.log_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload, ensure_ascii=False) + "\n")

    def do_GET(self) -> None:  # noqa: N802
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body) if body else {}
        except json.JSONDecodeError:
            parsed = {"raw": body}
        self._record(
            {
                "path": self.path,
                "authorization": self.headers.get("authorization", ""),
                "x_api_key": self.headers.get("x-api-key", ""),
                "model": parsed.get("model", ""),
                "max_tokens": parsed.get("max_tokens", ""),
            }
        )
        response = {
            "id": "msg_mock",
            "type": "message",
            "role": "assistant",
            "model": parsed.get("model", "mock"),
            "content": [{"type": "text", "text": "MOCK-RESPONSE"}],
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
        raw = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main() -> None:
    port = int(sys.argv[1])
    log_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    Handler.log_path = log_path
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock-anthropic listening on 127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
