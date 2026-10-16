#!/usr/bin/env python3
"""Only an owned loopback HTTP server; synthetic API tokens and inventory."""
import json
import subprocess
import sys
import threading
import time
import pathlib
import ssl
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from InventoryIntegrationTests import fixture
from TunnelIntegrationTests import reachable


class Fixture(BaseHTTPRequestHandler):
    requests = []
    failures = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        self.failures.append("unexpected mutation")
        self.send_error(405)

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST

    def send_json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parts = urlsplit(self.path)
        path = parts.path
        self.requests.append(path)
        if path == "/credential-leak":
            self.failures.append("redirect followed")
            return self.send_error(500)
        authorization = self.headers.get("Authorization", "")
        expected = "Bearer nbt_fixture.synthetic-token" if path.startswith("/api/dcim/") or path.startswith("/api/virtualization/") else "PVEAPIToken=reader@pve!hub=fixture-token-only"
        if authorization != expected:
            self.failures.append("incorrect synthetic authorization")
            return self.send_error(401)
        if path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", "/credential-leak")
            self.end_headers()
            return
        if path.startswith("/unauthorized/"):
            return self.send_error(401)
        if path.startswith("/large/"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(3 * 1024 * 1024))
            self.end_headers()
            try:
                for _ in range(48):
                    self.wfile.write(b"x" * 65536)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path.startswith("/stream/"):
            self.send_response(200)
            self.end_headers()
            try:
                for _ in range(40):
                    self.wfile.write(b"x" * 65536)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path.startswith("/slow/"):
            time.sleep(3)
            return self.send_json({"data": []})
        if path == "/api2/json/cluster/resources":
            return self.send_json({"data": [
                {"id": "node/pve1", "type": "node", "node": "pve1", "status": "online"},
                {"id": "qemu/100", "type": "qemu", "node": "pve1", "vmid": 100, "name": "demo-vm", "status": "running"},
                {"id": "lxc/101", "type": "lxc", "node": "pve1", "vmid": 101, "name": "demo-lxc", "status": "running"},
            ]})
        if path == "/api2/json/nodes/pve1/qemu/100/agent/network-get-interfaces":
            return self.send_json({"data": {"result": [{"name": "eth0", "ip-addresses": [{"ip-address": "192.0.2.21"}]}]}})
        if path == "/api2/json/cluster/status":
            return self.send_json({"data": [{"type": "node", "name": "pve1", "ip": "192.0.2.10", "online": 1}]})
        if path == "/api2/json/nodes/pve1/lxc/101/interfaces":
            return self.send_json({"data": [{"name": "eth0", "inet": "192.0.2.22/24"}]})
        if path == "/api/dcim/devices/":
            query = parse_qs(parts.query)
            fields = query.get("fields", [""])[0]
            if "custom_fields" in fields or "config_context" in fields or "fields" not in query:
                self.failures.append("unsafe NetBox field request")
            offset = int(query.get("offset", [0])[0])
            if offset == 0:
                return self.send_json({"count": 2, "next": "https://attacker.invalid/must-not-follow", "results": [{"id": 1, "name": "nbt_fixture.synthetic-token", "primary_ip4": {"address": "192.0.2.31/24"}}]})
            if offset == 1:
                return self.send_json({"count": 2, "next": None, "results": [{"id": 2, "name": "switch-2"}]})
            self.failures.append("unexpected pagination")
            return self.send_error(400)
        if path == "/api/virtualization/virtual-machines/":
            return self.send_json({"count": 1, "next": None, "results": [{"id": 1, "name": "netbox-vm", "primary_ip4": {"address": "192.0.2.40/24"}}]})
        self.failures.append("unexpected endpoint")
        self.send_error(404)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    tls_server = None
    try:
        with tempfile.TemporaryDirectory(prefix="ssh-hub-infrastructure-fixture-", dir="/private/tmp") as folder:
            root = pathlib.Path(folder)
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", str(root / "tls.key"), "-out", str(root / "tls.crt")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (root / "tls.key").chmod(0o600)
            tls_server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls_context.load_cert_chain(root / "tls.crt", root / "tls.key")
            tls_server.socket = tls_context.wrap_socket(tls_server.socket, server_side=True)
            threading.Thread(target=tls_server.serve_forever, daemon=True).start()
            subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}", f"https://127.0.0.1:{tls_server.server_port}"], check=True, timeout=20)
            commands = json.loads(subprocess.run([sys.argv[1], "--docker-commands"], check=True, capture_output=True, text=True).stdout)
            with fixture(root / "ssh", commands["list"]) as (config, unused):
                ssh = root / "ssh"
                handler = ssh / "handler.py"
                container_id = "a" * 64
                responses = {
                    commands["list"]: json.dumps({"ID": container_id, "Names": "web-fixture", "Image": "nginx:alpine", "State": "running", "Ports": "8080->80/tcp", "Networks": "bridge"}),
                    commands["inspect"]: json.dumps({"ID": container_id, "Networks": [{"Name": "bridge", "IPv4": "172.17.0.2"}, None]}),
                }
                (ssh / "responses.json").write_text(json.dumps(responses))
                handler.write_text('''import os,pathlib,json,sys
root=pathlib.Path(__file__).parent
command=os.environ.get("SSH_ORIGINAL_COMMAND", "")
responses=json.loads((root/"responses.json").read_text())
if command not in responses:sys.exit(91)
(root/"started").write_text("started")
print(responses[command])
''')
                known_before = (ssh / "known_hosts").read_bytes()
                for alias in ("inventory-test", "through-hop"):
                    subprocess.run([sys.argv[1], "--docker", str(config), alias], check=True, timeout=15)
                unknown = ssh / "unknown-config"
                unknown.write_text(config.read_text().replace(str(ssh / "known_hosts"), str(ssh / "empty_known_hosts")))
                (ssh / "started").unlink(missing_ok=True)
                subprocess.run([sys.argv[1], "--docker-reject", str(unknown), "through-hop"], check=True, timeout=15)
                assert not (ssh / "started").exists(), "untrusted SSH reached Docker collector"
                assert (ssh / "known_hosts").read_bytes() == known_before, "known_hosts changed"
                assert (ssh / "empty_known_hosts").read_bytes() == b"", "unknown SSH key accepted"
                assert not (ssh / "should-not-exist").exists(), "inherited LocalCommand ran"
                assert not reachable(unused), "inherited LocalForward opened"
        if Fixture.failures:
            raise RuntimeError("; ".join(Fixture.failures))
        if any(path.startswith(("/api/users/", "/api2/json/access/")) for path in Fixture.requests):
            raise RuntimeError("unexpected credential endpoint")
        print("InfrastructureIntegrationTests.py: passed")
    finally:
        if tls_server:
            tls_server.shutdown()
            tls_server.server_close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
