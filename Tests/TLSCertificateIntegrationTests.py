"""Owned loopback TLS/SOCKS fixtures; never changes system trust or contacts user servers."""
import pathlib
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import tempfile
import threading

seen = []


def exact(sock, count):
    data = b''
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(12)
            version, count = exact(self.request, 2)
            assert version == 5 and 0 in exact(self.request, count)
            self.request.sendall(b'\x05\x00')
            version, command, _, kind = exact(self.request, 4)
            assert version == 5 and command == 1
            if kind == 1:
                host = socket.inet_ntoa(exact(self.request, 4))
            elif kind == 3:
                host = exact(self.request, exact(self.request, 1)[0]).decode('ascii')
            elif kind == 4:
                host = socket.inet_ntop(socket.AF_INET6, exact(self.request, 16))
            else:
                raise AssertionError('bad address')
            port = struct.unpack('!H', exact(self.request, 2))[0]
            assert host in ('localhost', '127.0.0.1', '::1') and port == self.server.tls_port
            seen.append(self.server.reject)
            if self.server.reject:
                self.request.sendall(b'\x05\x02\x00\x01' + b'\0' * 6)
                return
            with socket.create_connection(('127.0.0.1', port), timeout=10) as upstream:
                self.request.sendall(b'\x05\x00\x00\x01' + b'\0' * 6)
                sockets = [self.request, upstream]
                while True:
                    ready, _, _ = select.select(sockets, [], [], 12)
                    if not ready:
                        return
                    for current in ready:
                        data = current.recv(65536)
                        if not data:
                            return
                        (upstream if current is self.request else self.request).sendall(data)
        except (EOFError, OSError):
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


with tempfile.TemporaryDirectory(prefix='ssh-hub-cert-', dir='/private/tmp') as name:
    root = pathlib.Path(name)
    (root / 'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n')
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(root / 'cert.cnf'), '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/openssl', 'x509', '-in', str(root / 'cert.pem'), '-outform', 'DER', '-out', str(root / 'cert.der')], check=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0)); listener.listen(); listener.settimeout(.2)
    stop = threading.Event()

    def serve():
        while not stop.is_set():
            try:
                stream, _ = listener.accept()
            except (TimeoutError, socket.timeout):
                continue
            except OSError:
                return
            try:
                stream.settimeout(5)
                with context.wrap_socket(stream, server_side=True):
                    pass
            except (ssl.SSLError, OSError):
                stream.close()

    thread = threading.Thread(target=serve, daemon=True); thread.start()
    proxies = [Server(('127.0.0.1', 0), Proxy), Server(('127.0.0.1', 0), Proxy)]
    for index, proxy in enumerate(proxies):
        proxy.reject = bool(index); proxy.tls_port = listener.getsockname()[1]
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
    try:
        subprocess.run([sys.argv[1], '--tls-snapshot', str(listener.getsockname()[1]), str(root / 'cert.der'), str(proxies[0].server_address[1]), str(proxies[1].server_address[1])], check=True, timeout=50)
        assert False in seen and True in seen
    finally:
        stop.set(); listener.close()
        for proxy in proxies:
            proxy.shutdown(); proxy.server_close()
print('PASS owned TLS certificate integration')
