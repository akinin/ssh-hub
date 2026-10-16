#!/usr/bin/env python3
"""Owned loopback Responses fixture; no OpenAI request or real API key."""
import json
import pathlib
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture(BaseHTTPRequestHandler):
    failures = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        provider = self.provider()
        if provider == "openAI":
            self.failures.append("unexpected GET or redirect")
            return self.send_error(405)
        if not self.authorize(provider):
            return
        if self.path.endswith("models-redirect"):
            self.send_response(307)
            self.send_header("Location", "/leak")
            self.end_headers()
            return
        if self.path == "/api/tags":
            return self.reply(200, {"models": [{"name": "ollama-fixture:latest"}]})
        if self.path == "/v1/models":
            return self.reply(200, {"data": [{"id": "compatible-fixture"}]})
        self.failures.append("unexpected model list endpoint")
        self.send_error(404)

    def provider(self):
        if self.path in ("/api/chat", "/api/tags") or self.path.startswith("/ollama/"):
            return "ollama"
        if self.path in ("/v1/chat/completions", "/v1/models") or self.path.startswith("/compatible/"):
            return "compatible"
        return "openAI"

    def authorize(self, provider):
        authorization = self.headers.get("Authorization")
        if provider == "openAI":
            allowed = authorization == "Bearer fixture-assistant-secret"
        else:
            allowed = authorization in (None, "Bearer fixture-" + provider + "-secret")
        if not allowed:
            self.failures.append("incorrect or mixed synthetic provider authorization")
            self.send_error(401)
        return allowed

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        if self.path == "/leak":
            self.failures.append("redirect followed with POST")
            return self.send_error(500)
        provider = self.provider()
        if not self.authorize(provider):
            return
        size = int(self.headers.get("Content-Length", 0))
        if size > 700_000:
            self.failures.append("request exceeds bound")
            return self.send_error(413)
        request = json.loads(self.rfile.read(size))
        valid = "tools" not in request
        if provider == "openAI":
            valid = valid and request.get("model") == "fixture-model" and request.get("store") is False and request.get("max_output_tokens") == 4096 and "messages" not in request
        elif provider == "ollama":
            valid = valid and request.get("model") == "ollama-fixture" and request.get("stream") is False and request.get("options", {}).get("num_predict") == 4096 and "store" not in request
        else:
            valid = valid and request.get("model") == "compatible-fixture" and request.get("stream") is False and request.get("max_tokens") == 4096 and "store" not in request
        if provider != "openAI":
            messages = request.get("messages", [])
            valid = valid and len(messages) >= 2 and messages[0].get("role") == "system" and messages[-1].get("role") == "user" and all(message.get("role") in ("system", "user", "assistant") and isinstance(message.get("content"), str) for message in messages)
        if not valid:
            self.failures.append("unexpected Responses request policy")
            return self.send_error(400)
        route = self.path.rsplit("/", 1)[-1]
        if route == "redirect":
            self.send_response(307)
            self.send_header("Location", "/leak")
            self.end_headers()
            return
        if route in ("large", "stream"):
            self.send_response(200)
            if route == "large":
                self.send_header("Content-Length", str(2 * 1024 * 1024))
            self.end_headers()
            try:
                for _ in range(32):
                    self.wfile.write(b"x" * 65536)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if route in ("unauthorized", "limited"):
            return self.reply(401 if route == "unauthorized" else 429, {"error": {"message": "fixture-assistant-secret must not be in error"}})
        if route == "slow":
            time.sleep(3)
        if provider == "ollama":
            return self.reply(200, {"done": True, "done_reason": "stop", "message": {"role": "assistant", "content": "Ollama fixture advice"}})
        if provider == "compatible":
            return self.reply(200, {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "Compatible fixture advice"}}]})
        value = "fixture-assistant-secret" if self.path == "/echo" else "Fixture advice"
        self.reply(200, {"status": "completed", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": value}]}]})


def main():
    http = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    tls = None
    try:
        with tempfile.TemporaryDirectory(prefix="ssh-hub-assistant-fixture-", dir="/private/tmp") as folder:
            root = pathlib.Path(folder)
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", str(root / "tls.key"), "-out", str(root / "tls.crt")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (root / "tls.key").chmod(0o600)
            tls = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(root / "tls.crt", root / "tls.key")
            tls.socket = context.wrap_socket(tls.socket, server_side=True)
            threading.Thread(target=tls.serve_forever, daemon=True).start()
            subprocess.run([sys.argv[1], f"http://127.0.0.1:{http.server_port}", f"https://127.0.0.1:{tls.server_port}"], check=True, timeout=20)
            if Fixture.failures:
                raise RuntimeError("; ".join(Fixture.failures))
            print("AIAssistantIntegrationTests.py: passed (no live API calls)")
    finally:
        if tls:
            tls.shutdown()
            tls.server_close()
        http.shutdown()
        http.server_close()


if __name__ == "__main__":
    main()
