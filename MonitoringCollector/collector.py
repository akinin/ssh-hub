#!/usr/bin/env python3
"""SSH Hub monitoring collector. Explicit TCP/HTTP probes, read-only authenticated API."""
import argparse
import concurrent.futures
import contextlib
import hashlib
import hmac
import http.client
import http.server
import json
import math
import multiprocessing
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import ssl
import stat
import threading
import time
import urllib.parse

MAX_TARGETS = 256
MAX_ROWS = 500_000
MAX_BODY = 2 * 1024 * 1024
ID = re.compile(r"[A-Za-z0-9_.-]{1,80}\Z")


def load_config(path):
    with open(path, "rb") as source:
        data = source.read(262145)
    if len(data) > 262144:
        raise ValueError("Configuration exceeds 256 KiB")
    value = json.loads(data)
    if not isinstance(value, dict) or set(value) - {"listen", "port", "concurrency", "retention_days", "targets"}:
        raise ValueError("Unknown configuration field")
    listen = value.get("listen", "127.0.0.1")
    # This HTTP listener belongs behind a local TLS reverse proxy, never the LAN.
    if listen not in ("127.0.0.1", "::1"):
        raise ValueError("listen must be a literal loopback address; use a TLS reverse proxy")
    port = bounded_int(value.get("port", 8787), 1, 65535)
    concurrency = bounded_int(value.get("concurrency", 8), 1, 16)
    retention = bounded_int(value.get("retention_days", 30), 1, 90)
    targets = value.get("targets", [])
    if not isinstance(targets, list) or not 1 <= len(targets) <= MAX_TARGETS:
        raise ValueError("Configure 1–256 targets")
    seen = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) - {"id", "name", "kind", "host", "port", "url", "interval_seconds", "timeout_seconds", "expected_status"}:
            raise ValueError("Unknown target field")
        key = target.get("id", "")
        if not isinstance(key, str) or not ID.fullmatch(key) or key in seen:
            raise ValueError("Target IDs must be unique ASCII identifiers")
        seen.add(key)
        name = target.get("name", key)
        if not isinstance(name, str) or not name or len(name.encode()) > 200 or any(ord(c) < 32 for c in name):
            raise ValueError("Invalid target name")
        target["name"] = name
        kind = target.get("kind", "tcp")
        if kind not in ("tcp", "http", "wan"):
            raise ValueError("Target kind must be tcp, http or wan")
        target["kind"] = kind
        target["interval_seconds"] = bounded_int(target.get("interval_seconds", 60), 10, 86400)
        timeout = target.get("timeout_seconds", 5)
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not .2 <= timeout <= 15:
            raise ValueError("Timeout must be 0.2–15 seconds")
        target["timeout_seconds"] = timeout
        if "url" in target:
            url = target["url"]
            if not isinstance(url, str) or len(url) > 2048 or any(c.isspace() or ord(c) < 32 for c in url):
                raise ValueError("Invalid HTTP target URL")
            parts = urllib.parse.urlsplit(url)
            if parts.scheme not in ("http", "https") or not parts.hostname or parts.username is not None or parts.password is not None or parts.query or parts.fragment:
                raise ValueError("HTTP target URL must not contain credentials, query or fragment")
            if parts.port is not None:
                bounded_int(parts.port, 1, 65535)
            expected = target.get("expected_status", [200, 204])
            if not isinstance(expected, list) or not 1 <= len(expected) <= 20:
                raise ValueError("Invalid expected HTTP status list")
            target["expected_status"] = [bounded_int(code, 200, 599) for code in expected]
        else:
            if kind == "http":
                raise ValueError("HTTP target requires url")
            host = target.get("host", "")
            if not isinstance(host, str) or not host or len(host) > 253 or any(c.isspace() or ord(c) < 32 for c in host) or any(c in host for c in "/@?#"):
                raise ValueError("Invalid TCP target host")
            target["port"] = bounded_int(target.get("port", 443), 1, 65535)
    return {"listen": listen, "port": port, "concurrency": concurrency, "retention_days": retention, "targets": targets}


def bounded_int(value, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError("Numeric setting is outside its allowed range")
    return value


def read_token():
    token_file = os.environ.get("SSH_HUB_MONITOR_TOKEN_FILE")
    if token_file:
        info = os.stat(token_file, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise ValueError("Token file must be a regular file with permissions 0600")
        fd = os.open(token_file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "r", encoding="utf-8") as source:
            token = source.read(4097).strip()
    else:
        token = os.environ.get("SSH_HUB_MONITOR_TOKEN", "")
    if not 32 <= len(token) <= 4096 or not all(33 <= ord(c) <= 126 for c in token):
        raise ValueError("Set a random API token of at least 32 printable ASCII characters via environment or protected file")
    return token


def probe_child(target, pipe):
    """The parent kills this process at its deadline, including a stuck DNS lookup."""
    started = time.monotonic()
    status = None
    detail = "unreachable"
    reachable = False
    try:
        timeout = target["timeout_seconds"]
        if "url" in target:
            parts = urllib.parse.urlsplit(target["url"])
            connection_type = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
            kwargs = {"timeout": timeout}
            if parts.scheme == "https":
                kwargs["context"] = ssl.create_default_context()
            connection = connection_type(parts.hostname, parts.port, **kwargs)
            try:
                # HEAD reads headers only. Redirects are not followed; no response content is retained.
                connection.request("HEAD", parts.path or "/", headers={"User-Agent": "SSH-Hub-Monitor/1", "Connection": "close"})
                response = connection.getresponse()
                status = response.status
                reachable = status in target["expected_status"]
                detail = "http_ok" if reachable else "http_status"
            finally:
                connection.close()
        else:
            with socket.create_connection((target["host"], target["port"]), timeout=timeout):
                reachable = True
                detail = "tcp_open"
    except ssl.SSLError:
        detail = "tls_error"
    except (TimeoutError, socket.timeout):
        detail = "timeout"
    except (OSError, ValueError, http.client.HTTPException):
        detail = "unreachable"
    with contextlib.suppress(BrokenPipeError, EOFError, OSError):
        pipe.send({"reachable": reachable, "latency_ms": round((time.monotonic() - started) * 1000, 2), "detail": detail, "status_code": status})
    pipe.close()


def probe(target):
    context = multiprocessing.get_context("spawn")
    read, write = context.Pipe(duplex=False)
    process = context.Process(target=probe_child, args=(target, write), daemon=True)
    started = time.monotonic()
    try:
        process.start()
        write.close()
        deadline = target["timeout_seconds"] + 1
        if read.poll(deadline):
            try:
                return read.recv()
            except EOFError:
                pass
        return {"reachable": False, "latency_ms": round((time.monotonic() - started) * 1000, 2), "detail": "timeout", "status_code": None}
    finally:
        write.close()
        read.close()
        if process.pid is not None:
            process.join(.1)
            if process.is_alive():
                process.terminate()
                process.join(1)
            if process.is_alive():
                process.kill()
                process.join(1)
            process.close()


class History:
    def __init__(self, path, retention_days):
        self.lock = threading.RLock()
        self.retention_days = retention_days
        self.path = Path(path)
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.path.is_symlink():
            raise ValueError("Database must not be a symbolic link")
        self.db = sqlite3.connect(str(path), check_same_thread=False, timeout=5)
        os.chmod(path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.execute("CREATE TABLE IF NOT EXISTS samples (sequence INTEGER PRIMARY KEY, target TEXT NOT NULL, checked_at REAL NOT NULL, reachable INTEGER NOT NULL, latency_ms REAL NOT NULL, detail TEXT NOT NULL, status_code INTEGER)")
        self.db.execute("CREATE INDEX IF NOT EXISTS samples_target_time ON samples(target, checked_at DESC)")
        self.db.commit()
        self.last_prune = 0
        self.prune()

    def add(self, key, result, checked_at=None):
        with self.lock:
            cursor = self.db.execute("INSERT INTO samples(target, checked_at, reachable, latency_ms, detail, status_code) VALUES(?,?,?,?,?,?)", (key, checked_at or time.time(), int(result["reachable"]), result["latency_ms"], result["detail"], result["status_code"]))
            self.db.execute("DELETE FROM samples WHERE sequence <= ?", (cursor.lastrowid - MAX_ROWS,))
            self.db.commit()
            if time.monotonic() - self.last_prune > 60:
                self.prune()

    def prune(self):
        with self.lock:
            self.db.execute("DELETE FROM samples WHERE checked_at < ?", (time.time() - self.retention_days * 86400,))
            self.db.execute("DELETE FROM samples WHERE sequence <= COALESCE((SELECT sequence FROM samples ORDER BY sequence DESC LIMIT 1 OFFSET ?),0)", (MAX_ROWS,))
            self.db.commit()
            self.last_prune = time.monotonic()

    @staticmethod
    def row(row):
        return {"id": row[0], "target_id": row[1], "checked_at": row[2], "reachable": bool(row[3]), "latency_ms": row[4], "detail": row[5], "status_code": row[6]}

    def history(self, key, limit):
        with self.lock:
            rows = self.db.execute("SELECT * FROM samples WHERE target=? ORDER BY sequence DESC LIMIT ?", (key, limit)).fetchall()
        return [self.row(row) for row in rows]

    def summary(self, target):
        key = target["id"]
        with self.lock:
            latest = self.db.execute("SELECT * FROM samples WHERE target=? ORDER BY sequence DESC LIMIT 1", (key,)).fetchone()
            count, up = self.db.execute("SELECT count(*), sum(reachable) FROM samples WHERE target=? AND checked_at>=?", (key, time.time() - 86400)).fetchone()
        return {"id": key, "name": target["name"], "kind": target["kind"], "interval_seconds": target["interval_seconds"], "latest": self.row(latest) if latest else None, "samples_24h": count, "availability_24h": round(100 * (up or 0) / count, 3) if count else None}

    def close(self):
        with self.lock:
            self.db.close()


class Collector:
    def __init__(self, config, history):
        self.config = config
        self.history = history
        self.stop = threading.Event()
        self.started_at = time.time()
        self.error = None

    def run(self):
        next_due = {target["id"]: 0.0 for target in self.config["targets"]}
        pending = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.config["concurrency"], thread_name_prefix="monitor") as pool:
            while not self.stop.is_set():
                for future in tuple(pending):
                    if future.done():
                        target = pending.pop(future)
                        try:
                            self.history.add(target["id"], future.result())
                        except Exception:
                            self.error = "storage_error"
                            self.stop.set()
                            return
                busy = {target["id"] for target in pending.values()}
                due = sorted((target for target in self.config["targets"] if target["id"] not in busy and next_due[target["id"]] <= time.monotonic()), key=lambda target: next_due[target["id"]])
                for target in due[:self.config["concurrency"] - len(pending)]:
                    next_due[target["id"]] = time.monotonic() + target["interval_seconds"]
                    pending[pool.submit(probe, dict(target))] = target
                self.stop.wait(.2)

    def snapshot(self):
        return {"version": 1, "generated_at": time.time(), "started_at": self.started_at, "retention_days": self.config["retention_days"], "healthy": not self.stop.is_set() and self.error is None, "targets": [self.history.summary(target) for target in self.config["targets"]]}


class APIHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "SSHHubMonitor/1"
    sys_version = ""

    def log_message(self, *args):
        pass  # Never log Authorization, paths, target addresses or response data.

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def reply(self, code, value):
        body = json.dumps(value, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()
        if len(body) > MAX_BODY:
            code, body = 500, b'{"error":"response_limit"}'
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError, TimeoutError):
            self.wfile.write(body)

    def do_GET(self):
        auth = self.headers.get_all("Authorization", [])
        supplied = auth[0] if len(auth) == 1 else ""
        if len(supplied) > 4200 or not hmac.compare_digest(hashlib.sha256(supplied.encode()).digest(), self.server.auth_digest):
            self.reply(401, {"error": "unauthorized"})
            return
        if len(self.path) > 4096 or self.headers.get("Content-Length", "0") != "0" or self.headers.get("Transfer-Encoding"):
            self.reply(400, {"error": "invalid_request"})
            return
        parts = urllib.parse.urlsplit(self.path)
        if parts.path == "/v1/snapshot" and not parts.query:
            self.reply(200, self.server.collector.snapshot())
        elif parts.path == "/v1/history":
            try:
                query = urllib.parse.parse_qs(parts.query, max_num_fields=3)
            except ValueError:
                self.reply(400, {"error": "invalid_query"})
                return
            if set(query) - {"target", "limit"} or any(len(values) != 1 for values in query.values()):
                self.reply(400, {"error": "invalid_query"})
                return
            key = query.get("target", [""])[0]
            try:
                limit = int(query.get("limit", ["250"])[0])
                bounded_int(limit, 1, 1000)
                if key not in {target["id"] for target in self.server.collector.config["targets"]}:
                    raise ValueError()
            except ValueError:
                self.reply(400, {"error": "invalid_query"})
                return
            self.reply(200, {"version": 1, "target_id": key, "samples": self.server.collector.history.history(key, limit)})
        else:
            self.reply(404, {"error": "not_found"})

    def do_POST(self):
        self.reply(405, {"error": "read_only"})

    do_PUT = do_DELETE = do_PATCH = do_POST


class APIServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = True
    request_queue_size = 16

    def __init__(self, config, collector, token):
        self.slots = threading.BoundedSemaphore(16)
        if config["listen"] == "::1":
            self.address_family = socket.AF_INET6
        super().__init__((config["listen"], config["port"]), APIHandler)
        self.collector = collector
        self.auth_digest = hashlib.sha256(("Bearer " + token).encode()).digest()

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="Path to JSON check configuration (no secrets)")
    parser.add_argument("--database", required=True, help="Path to private SQLite history database")
    options = parser.parse_args()
    os.umask(0o077)
    try:
        config = load_config(options.config)
        token = read_token()
        history = History(options.database, config["retention_days"])
        collector = Collector(config, history)
        server = APIServer(config, collector, token)
    except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error):
        parser.exit(2, "Cannot start collector. Check configuration, token file permissions and database path.\n")
    thread = threading.Thread(target=collector.run, name="collector", daemon=True)
    thread.start()
    api = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .2}, name="api", daemon=True)
    api.start()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: collector.stop.set())
    try:
        while not collector.stop.wait(.5):
            pass
    finally:
        collector.stop.set()
        server.shutdown()
        api.join(6)
        server.server_close()
        thread.join(20)
        history.close()
    return 1 if collector.error else 0


if __name__ == "__main__":
    raise SystemExit(main())
