#!/usr/bin/env python3
"""Only an owned loopback HTTP server; synthetic API tokens and inventory."""
import json
import base64
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
        if path.startswith(("/proxy/network/integration/v1/", "/integration/v1/")):
            return self.unifi(parts)
        if path.startswith("/rest/"):
            return self.mikrotik(parts)
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



    def unifi(self, parts):
        key = self.headers.get("X-API-Key", "")
        if key not in ("fixture-unifi-key", "partial-unifi-key") or self.headers.get("Authorization"):
            self.failures.append("incorrect UniFi credential header")
            return self.send_error(401)
        site = "11111111-1111-4111-8111-111111111111"
        device = "22222222-2222-4222-8222-222222222222"
        client = "33333333-3333-4333-8333-333333333333"
        network = "44444444-4444-4444-8444-444444444444"
        tail = parts.path.split("/integration/v1", 1)[1]
        summary = {"id": device, "name": "USW fixture", "ipAddress": "192.0.2.10", "macAddress": "aa:bb:cc:dd:ee:01", "state": "ONLINE", "model": "USW Flex", "firmwareVersion": "7.2.1", "features": ["switching"]}
        network_row = {"id": network, "name": key, "vlanId": 20, "enabled": True}
        pages = {"/sites": [{"id": site, "name": "Fixture"}], f"/sites/{site}/devices": [summary], f"/sites/{site}/clients": [{"id": client, "name": "Fixture workstation", "ipAddress": "192.0.2.20", "type": "WIRED"}], f"/sites/{site}/networks": [network_row]}
        if key == "partial-unifi-key" and tail.endswith("/clients"):
            return self.send_error(403)
        if tail in pages:
            query = parse_qs(parts.query)
            if set(query) != {"limit", "offset"} or query["limit"] != ["100"] or query["offset"] != ["0"]:
                self.failures.append("unexpected UniFi pagination")
                return self.send_error(400)
            rows = pages[tail]
            return self.send_json({"offset": 0, "limit": 100, "count": len(rows), "totalCount": len(rows), "data": rows})
        if tail == f"/sites/{site}/devices/{device}":
            return self.send_json(dict(summary, interfaces={"ports": [{"idx": 1, "state": "UP", "speedMbps": 1000}]}, password="never-copy-unifi-password"))
        if tail == f"/sites/{site}/networks/{network}":
            return self.send_json(dict(network_row, ipv4Configuration={"hostIpAddress": "192.0.2.1", "prefixLength": 24}))
        self.failures.append("unexpected UniFi endpoint: " + tail)
        return self.send_error(404)

    def mikrotik(self, parts):
        authorization = self.headers.get("Authorization", "")
        try:
            scheme, encoded = authorization.split(" ", 1)
            username, password = base64.b64decode(encoded, validate=True).decode("utf-8").split(":", 1)
        except Exception:
            self.failures.append("bad RouterOS Basic header")
            return self.send_error(401)
        if scheme != "Basic" or password != "fixture password Ю" or username not in ("fixture-reader", "redirect-fixture", "denied-fixture"):
            self.failures.append("incorrect RouterOS credential")
            return self.send_error(401)
        if username == "redirect-fixture":
            self.send_response(302)
            self.send_header("Location", "/credential-leak")
            self.end_headers()
            return
        if username == "denied-fixture":
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="RouterOS fixture"')
            self.end_headers()
            return
        properties = {
            "/rest/system/resource": "version,board-name,architecture-name,cpu,cpu-count,cpu-frequency,cpu-load,total-memory,free-memory,total-hdd-space,uptime",
            "/rest/system/identity": "name",
            "/rest/system/routerboard": "model,serial-number,current-firmware",
            "/rest/interface": ".id,name,type,mac-address,running,disabled,actual-mtu",
            "/rest/ip/address": "address,interface,actual-interface,disabled,invalid",
            "/rest/ip/neighbor": "identity,address,address6,mac-address,interface,platform,board",
            "/rest/ip/dhcp-server/lease": "address,active-address,mac-address,active-mac-address,host-name,status,server",
            "/rest/interface/vlan": "name,vlan-id,interface,running,disabled",
        }
        query = parse_qs(parts.query)
        if parts.path not in properties or query != {".proplist": [properties[parts.path]]}:
            self.failures.append("unsafe RouterOS endpoint/proplist: " + parts.path)
            return self.send_error(400)
        responses = {
            "/rest/system/resource": [{"version": "7.18", "board-name": "hAP", "cpu": "ARM", "cpu-count": "4", "total-memory": "1073741824", "uptime": "1d"}],
            "/rest/system/identity": [{"name": "Router fixture"}],
            "/rest/system/routerboard": [{"model": "C52", "serial-number": password, "private-key": "never-copy-private-key"}],
            "/rest/interface": [{"name": "ether1", "type": "ether", "mac-address": "aa:bb:cc:dd:ee:01", "running": "true", "actual-mtu": "1500"}],
            "/rest/ip/address": [{"address": "192.0.2.1/24", "interface": "ether1"}],
            "/rest/ip/neighbor": [{"identity": "Neighbor fixture", "address": "192.0.2.20", "mac-address": "aa:bb:cc:dd:ee:02", "platform": "MikroTik", "board": "hAP"}],
            "/rest/ip/dhcp-server/lease": [{"address": "192.0.2.20", "mac-address": "aa:bb:cc:dd:ee:02", "host-name": "Neighbor fixture", "status": "bound"}],
            "/rest/interface/vlan": [{"name": "servers", "vlan-id": "20", "interface": "ether1"}],
        }
        return self.send_json(responses[parts.path])


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
            subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}", f"https://127.0.0.1:{tls_server.server_port}"], check=True, timeout=40)
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
        print("Tests/InfrastructureIntegrationTests.py: passed")
    finally:
        if tls_server:
            tls_server.shutdown()
            tls_server.server_close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
