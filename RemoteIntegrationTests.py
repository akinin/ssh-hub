#!/usr/bin/env python3
"""Local FTP/FTPS, WebDAV, VNC, Telnet and RDP fixtures. No user servers or data."""
import base64
import contextlib
import http.server
import os
import pathlib
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET


def exact(stream, count, timeout=15):
    result = b""
    deadline = time.monotonic() + timeout
    while len(result) < count:
        left = deadline - time.monotonic()
        fd = stream.fileno()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            raise TimeoutError("fixture read timeout")
        data = os.read(fd, min(65536, count - len(result)))
        if not data:
            raise EOFError("fixture EOF")
        result += data
    return result


def line(stream):
    result = b""
    while not result.endswith(b"\n"):
        result += exact(stream, 1)
    return result.decode().strip()


def ftp_child(root, certificate=None, key=None):
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
    from pyftpdlib.servers import FTPServer
    authorizer = DummyAuthorizer()
    authorizer.add_user("fixture", "fixture-secret", root, perm="elradfmwMT")
    handler = type("FixtureHandler", (TLS_FTPHandler if certificate else FTPHandler,), {})
    handler.authorizer = authorizer
    if certificate:
        handler.certfile = certificate
        handler.keyfile = key
        handler.tls_control_required = True
        handler.tls_data_required = True
    server = FTPServer(("127.0.0.1", 0), handler)
    print("PORT", server.socket.getsockname()[1], flush=True)
    server.serve_forever(timeout=0.1)


class DAV(http.server.BaseHTTPRequestHandler):
    root = None

    def log_message(self, *args):
        pass

    def authorized(self):
        if self.headers.get("Authorization") == "Basic " + base64.b64encode(b"fixture:fixture-secret").decode():
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def file(self, path=None):
        path = urllib.parse.unquote(urllib.parse.urlsplit(path or self.path).path)
        if not path.startswith("/dav/"):
            raise ValueError("outside DAV root")
        result = (self.root / path[5:]).resolve()
        if result != self.root and self.root not in result.parents:
            raise ValueError("traversal")
        return result

    def reply(self, code, body=b"", content="application/xml"):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", content)
        self.end_headers()
        self.wfile.write(body)

    def do_PROPFIND(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        folder = self.file()
        if not folder.is_dir():
            self.reply(404)
            return
        root = ET.Element("{DAV:}multistatus")
        for item in [folder] + list(folder.iterdir()):
            response = ET.SubElement(root, "{DAV:}response")
            relative = str(item.relative_to(self.root))
            href = "/dav/" + ("" if relative == "." else urllib.parse.quote(relative)) + ("/" if item.is_dir() and relative != "." else "")
            ET.SubElement(response, "{DAV:}href").text = href
            propstat = ET.SubElement(response, "{DAV:}propstat")
            prop = ET.SubElement(propstat, "{DAV:}prop")
            kind = ET.SubElement(prop, "{DAV:}resourcetype")
            if item.is_dir():
                ET.SubElement(kind, "{DAV:}collection")
            ET.SubElement(prop, "{DAV:}getcontentlength").text = str(item.stat().st_size)
            ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
        self.reply(207, ET.tostring(root))

    def do_MKCOL(self):
        if not self.authorized():
            return
        target = self.file()
        if target.exists():
            self.reply(405)
            return
        target.mkdir()
        self.reply(201)

    def do_PUT(self):
        if not self.authorized():
            return
        target = self.file()
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if target.exists() and self.headers.get("If-None-Match") == "*":
            self.reply(412)
            return
        target.write_bytes(data)
        self.reply(201)

    def do_GET(self):
        if self.authorized():
            self.reply(200, self.file().read_bytes(), "application/octet-stream")

    def do_MOVE(self):
        if not self.authorized():
            return
        source, target = self.file(), self.file(self.headers["Destination"])
        if target.exists() and self.headers.get("Overwrite") == "F":
            self.reply(412)
            return
        source.rename(target)
        self.reply(201)

    def do_DELETE(self):
        if not self.authorized():
            return
        target = self.file()
        target.rmdir() if target.is_dir() else target.unlink()
        self.reply(204)


def run_checked(args, timeout=60):
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    if result.returncode:
        raise AssertionError(result.stdout.decode(errors="replace") + result.stderr.decode(errors="replace"))
    print(result.stdout.decode().strip(), flush=True)


def vnc_fixture(listener, errors):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, modes
        from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
        with listener.accept()[0] as connection:
            connection.sendall(b"RFB 003.008\n")
            assert exact(connection, 12) == b"RFB 003.008\n"
            connection.sendall(b"\1\2")
            assert exact(connection, 1) == b"\2"
            challenge = bytes(range(16))
            connection.sendall(challenge)
            key = bytes(int(f"{b:08b}"[::-1], 2) for b in b"fixture-"[:8])
            cipher = Cipher(TripleDES(key * 3), modes.ECB()).encryptor()
            assert exact(connection, 16) == cipher.update(challenge) + cipher.finalize()
            connection.sendall(b"\0" * 4)
            assert exact(connection, 1) == b"\1"
            pixel_format = bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            connection.sendall(struct.pack("!HH", 2, 2) + pixel_format + struct.pack("!I", 7) + b"fixture")
            assert exact(connection, 20)[0] == 0
            encoding = exact(connection, 4)
            assert encoding[0] == 2
            exact(connection, struct.unpack("!H", encoding[2:])[0] * 4)
            assert exact(connection, 10)[0] == 3
            pixels = bytes([3, 2, 1, 0, 6, 5, 4, 0, 9, 8, 7, 0, 12, 11, 10, 0])
            connection.sendall(b"\0\0\0\1" + struct.pack("!HHHHi", 0, 0, 2, 2, 0) + pixels)
            pointer, keys = False, 0
            while not pointer or keys < 2:
                kind = exact(connection, 1)[0]
                if kind == 3:
                    exact(connection, 9)
                elif kind == 5:
                    payload = exact(connection, 5)
                    assert payload == b"\1\0\1\0\1"
                    pointer = True
                elif kind == 4:
                    payload = exact(connection, 7)
                    assert struct.unpack("!I", payload[3:])[0] == 0x01000416
                    keys += 1
                else:
                    raise AssertionError("unexpected VNC input")
    except Exception as error:
        errors.append(error)


def telnet_fixture(listener, errors):
    try:
        with listener.accept()[0] as connection:
            connection.sendall(b"fixture-output\r\n")
            data = b""
            while not data.endswith(b"\n"):
                data += exact(connection, 1)
    except Exception as error:
        errors.append(error)


def rdp_case(helper, fixture, certificate, key, root, approve, nla=False, wrong_password=False):
    root.mkdir(parents=True, exist_ok=True)
    sam = root / "SAM"
    if nla:
        digest = subprocess.run(["/usr/bin/openssl", "dgst", "-md4"], input="fixture-secret".encode("utf-16le"), check=True, capture_output=True).stdout.decode().strip().split()[-1]
        sam.write_text("fixture:::" + digest + ":\n")
        sam.chmod(0o600)
    server = subprocess.Popen([fixture, str(certificate), str(key)] + ([str(sam)] if nla else []), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    client = None
    try:
        port = line(server.stdout).split()[1]
        client = subprocess.Popen([helper, "127.0.0.1", port, "fixture", "", "640", "480", str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        secret = b"wrong-fixture" if wrong_password else b"fixture-secret"
        client.stdin.write(struct.pack("!I", len(secret)) + secret)
        client.stdin.flush()
        certificate_seen = False
        frame_count = 0
        while True:
            try:
                kind, size = struct.unpack("!II", exact(client.stdout, 8))
            except EOFError:
                if wrong_password and certificate_seen:
                    client.wait(timeout=5)
                    assert client.returncode != 0
                    print("PASS RDP NLA wrong password rejected", flush=True)
                    return
                raise
            assert size <= 34_000_008
            payload = exact(client.stdout, size)
            if kind == 1:
                frame_count += 1
            if kind == 2:
                certificate_seen = True
                assert b"127.0.0.1" in payload and len(payload) > 30
                client.stdin.write(struct.pack("!I", int(approve)))
                client.stdin.flush()
                if not approve:
                    client.wait(timeout=10)
                    assert client.returncode != 0
                    print("PASS RDP certificate rejection", flush=True)
                    return
            elif kind == 1 and payload[8:11] == b"\x11\x22\x33":
                assert certificate_seen
                assert struct.unpack("!II", payload[:8]) == (640, 480)
                for event in [(1, 0x9000, 12, 34), (2, 0, 0x416, 0), (2, 0x8000, 0x416, 0), (3, 0, 0x1C, 0)]:
                    client.stdin.write(struct.pack("!IIII", *event))
                client.stdin.flush()
                received = ""
                while "MOUSE 36864 12 34" not in received or "UNICODE 0 1046" not in received or "KEY 0 28" not in received:
                    received += line(server.stdout) + "\n"
                print("PASS RDP " + ("NLA/" if nla else "") + "TLS approval/framebuffer/mouse/Unicode/scancode", flush=True)
                return
    except Exception:
        if client and client.poll() is None:
            client.terminate()
        if server.poll() is None:
            server.terminate()
        if client:
            print(client.communicate(timeout=5)[1].decode(errors="replace"), file=sys.stderr)
        out, err = server.communicate(timeout=5)
        print(out.decode(errors="replace") + err.decode(errors="replace"), file=sys.stderr)
        raise
    finally:
        for process in [client, server]:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--ftp-child":
        ftp_child(sys.argv[2], *sys.argv[3:])
        return
    checks, rdp, fixture = sys.argv[1:4]
    with tempfile.TemporaryDirectory(prefix="ssh-hub-protocols-") as temporary:
        root = pathlib.Path(temporary)
        certificate, key = root / "cert.pem", root / "key.pem"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(certificate), "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], check=True, capture_output=True)
        run_checked([checks])
        for secure in [False, True]:
            folder = root / ("ftps" if secure else "ftp")
            folder.mkdir()
            command = [sys.executable, __file__, "--ftp-child", str(folder)] + ([str(certificate), str(key)] if secure else [])
            server = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                port = line(server.stdout).split()[1]
                run_checked([checks, "--files", "ftps" if secure else "ftp", port] + ([str(certificate)] if secure else []))
            finally:
                server.terminate()
                server.wait(timeout=5)
        DAV.root = (root / "dav").resolve()
        DAV.root.mkdir()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DAV)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run_checked([checks, "--files", "webdav", str(server.server_port)])
        finally:
            server.shutdown()
            server.server_close()
        for mode, function in [("--vnc", vnc_fixture), ("--telnet", telnet_fixture)]:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                listener.settimeout(15)
                errors = []
                worker = threading.Thread(target=function, args=(listener, errors), daemon=True)
                worker.start()
                run_checked([checks, mode, str(listener.getsockname()[1])] + ([str(pathlib.Path(rdp).with_name("SSHTelnet"))] if mode == "--telnet" else []))
                worker.join(timeout=5)
                assert not worker.is_alive() and not errors, errors
        rdp_case(rdp, fixture, certificate, key, root / "rdp-reject", False)
        rdp_case(rdp, fixture, certificate, key, root / "rdp-accept", True)
        rdp_case(rdp, fixture, certificate, key, root / "rdp-nla", True, nla=True)
        rdp_case(rdp, fixture, certificate, key, root / "rdp-wrong", True, nla=True, wrong_password=True)
    print("Remote integration checks passed; only temporary localhost fixtures used.")


if __name__ == "__main__":
    main()
