#!/usr/bin/env python3
"""Minimal OpenAI-compatible chat-completions mock for the reasoning smoke test.

Responds to any POST with a fixed choices[0].message.content, so CI can drive
the whole reasoning path end to end (extension -> fractalsql-reasoning-http.so
-> HTTP POST -> response parse -> text back to psql) without a real LLM.

Usage: python3 mock_llm.py [port]   (default port 18080)

Not for production use — no auth, no TLS, single canned reply.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REPLY = "pong-from-mock"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)
        body = json.dumps(
            {"choices": [{"message": {"role": "assistant", "content": REPLY}}]}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # keep CI logs quiet


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
