#!/usr/bin/env python3
import concurrent.futures
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import collector
TOKEN = "t" * 40


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        status = 503 if self.path == "/down" else 302 if self.path == "/redirect" else 200
        self.send_response(status)
        self.send_header("Content-Length", "0")
        if status == 302:
            self.send_header("Location", "/must-not-follow")
        self.end_headers()

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.respond(401, {})
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/v1/snapshot")
            self.end_headers()
        elif self.path == "/oversize":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(collector.MAX_BODY + 1))
            self.end_headers()
        elif self.path == "/slow":
            time.sleep(2)
            self.respond(200, {})
        elif self.path.startswith("/v1/history"):
            self.respond(200, {"version": 1, "target_id": "fixture", "samples": [sample()]})
        else:
            self.respond(200, {"version": 1, "generated_at": time.time(), "started_at": time.time() - 60, "retention_days": 30, "healthy": True, "targets": [{"id": "fixture", "name": "Fixture", "kind": "wan", "interval_seconds": 10, "latest": sample(), "samples_24h": 1, "availability_24h": 100}]})

    def respond(self, code, data):
        data = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)


def sample():
    return {"id": 1, "target_id": "fixture", "checked_at": time.time(), "reachable": True, "latency_ms": 5, "detail": "tcp_open", "status_code": None}


def blocked_probe(target, pipe):
    time.sleep(10)


def api(port, path, token=TOKEN, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, headers={"Authorization": "Bearer " + token})
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        cls.fixture.daemon_threads = True
        cls.port = cls.fixture.server_port
        cls.thread = threading.Thread(target=cls.fixture.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.fixture.shutdown()
        cls.fixture.server_close()
        cls.thread.join()

    def test_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.json"
            good = {"targets": [{"id": "wan1", "name": "WAN1", "kind": "wan", "host": "127.0.0.1", "port": self.port}]}
            path.write_text(json.dumps(good))
            self.assertEqual(collector.load_config(path)["targets"][0]["kind"], "wan")
            for bad in [dict(good, listen="0.0.0.0"), {"targets": good["targets"] * 2}, {"targets": [{"id": "http", "kind": "http", "url": "https://user:secret@example.com"}]}, {"targets": [{"id": "http", "kind": "http", "url": "https://example.com?token=secret"}]}, {"targets": [{"id": "tcp", "host": "127.0.0.1", "timeout_seconds": 99}]}]:
                path.write_text(json.dumps(bad))
                with self.assertRaises(ValueError):
                    collector.load_config(path)

    def test_isolated_probe(self):
        target = {"host": "127.0.0.1", "port": self.port, "timeout_seconds": 1}
        self.assertTrue(collector.probe(target)["reachable"])
        for route, expected in [("/", True), ("/down", False), ("/redirect", False)]:
            result = collector.probe({"url": f"http://127.0.0.1:{self.port}{route}", "expected_status": [200], "timeout_seconds": 1})
            self.assertEqual(result["reachable"], expected)

    def test_hard_deadline(self):
        original = collector.probe_child
        collector.probe_child = blocked_probe
        started = time.monotonic()
        try:
            result = collector.probe({"timeout_seconds": .2})
            self.assertEqual(result["detail"], "timeout")
            self.assertLess(time.monotonic() - started, 3)
        finally:
            collector.probe_child = original

    def test_history_and_retention(self):
        with tempfile.TemporaryDirectory() as folder:
            history = collector.History(Path(folder) / "history.sqlite", 1)
            try:
                result = {"reachable": True, "latency_ms": 2, "detail": "tcp_open", "status_code": None}
                history.add("fixture", result, checked_at=time.time() - 2 * 86400)
                history.add("fixture", result)
                history.add("fixture", dict(result, reachable=False))
                history.prune()
                target = {"id": "fixture", "name": "Fixture", "kind": "tcp", "interval_seconds": 10}
                summary = history.summary(target)
                self.assertEqual(summary["availability_24h"], 50)
                self.assertEqual(len(history.history("fixture", 1)), 1)
                self.assertEqual(len(history.history("fixture", 1000)), 2)
                self.assertEqual(os.stat(history.path).st_mode & 0o777, 0o600)
                original = collector.MAX_ROWS
                collector.MAX_ROWS = 2
                try:
                    for _ in range(4):
                        history.add("fixture", result)
                    self.assertEqual(len(history.history("fixture", 1000)), 2)
                finally:
                    collector.MAX_ROWS = original
            finally:
                history.close()

    def test_running_service(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
            sock.close()
            config = {"port": port, "targets": [{"id": "tcp", "name": "TCP fixture", "host": "127.0.0.1", "port": self.port, "interval_seconds": 10}, {"id": "wan", "name": "WAN fixture", "kind": "wan", "url": f"http://127.0.0.1:{self.port}/down", "interval_seconds": 10}]}
            (folder / "config.json").write_text(json.dumps(config))
            (folder / "token").write_text(TOKEN)
            os.chmod(folder / "token", 0o600)
            env = dict(os.environ, SSH_HUB_MONITOR_TOKEN_FILE=str(folder / "token"))
            process = subprocess.Popen([sys.executable, str(HERE / "collector.py"), "--config", str(folder / "config.json"), "--database", str(folder / "history.sqlite")], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                snapshot = None
                while time.monotonic() < deadline:
                    try:
                        code, snapshot = api(port, "/v1/snapshot")
                        if code == 200 and all(target["latest"] for target in snapshot["targets"]):
                            break
                    except (OSError, http.client.HTTPException):
                        pass
                    time.sleep(.1)
                self.assertIsNotNone(snapshot)
                self.assertTrue(all(target["latest"] for target in snapshot["targets"]))
                self.assertEqual(api(port, "/v1/snapshot", token="bad")[0], 401)
                self.assertEqual(api(port, "/v1/snapshot", method="POST")[0], 405)
                self.assertEqual(api(port, "/v1/history?target=tcp&limit=1001")[0], 400)
                self.assertEqual(api(port, "/v1/history?target=unknown")[0], 400)
                code, history = api(port, "/v1/history?target=tcp&limit=10")
                self.assertEqual(code, 200)
                self.assertTrue(history["samples"][0]["reachable"])
                self.assertFalse(next(target for target in snapshot["targets"] if target["id"] == "wan")["latest"]["reachable"])
                self.assertNotIn(TOKEN, json.dumps(snapshot))
                self.assertNotIn("127.0.0.1", json.dumps(snapshot))
            finally:
                process.terminate()
                stdout, stderr = process.communicate(timeout=25)
                self.assertNotIn(TOKEN.encode(), stdout + stderr)
                self.assertEqual(process.returncode, 0, stderr.decode())

    def test_native_client(self):
        if len(sys.argv) < 2:
            self.skipTest("Pass compiled MonitoringTests executable to exercise native client")
        result = subprocess.run([sys.argv[1], f"http://127.0.0.1:{self.port}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout.decode() + result.stderr.decode())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
