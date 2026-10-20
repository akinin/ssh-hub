import base64
import http.server
import pathlib
import struct
import subprocess
import sys
import ssl
import tempfile
import threading
import time
import zlib

def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 64, 32, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + bytes([0, 120, 255, 255]) * 64) * 32)) + chunk(b'IEND', b'')
ico = struct.pack('<HHH', 0, 1, 1) + struct.pack('<BBBBHHII', 64, 32, 0, 0, 1, 32, len(png), 22) + png
class Handler(http.server.BaseHTTPRequestHandler):
    credentials_received = False
    def log_message(self, *args): pass
    def do_GET(self):
        if self.headers.get('Cookie') or self.headers.get('Authorization'):
            Handler.credentials_received = True
        path = self.path.split('?')[0]
        if path == '/favicon.ico' and getattr(self.server, 'tls_fixture', False):
            self.send_response(404); self.end_headers(); return
        if path == '/external-icon':
            content = ('<link rel="icon" href="%s/icons/site.ico">' % self.server.other_base).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.send_header('Content-Length', str(len(content))); self.end_headers(); self.wfile.write(content); return
        if path == '/redirect-other':
            self.send_response(302); self.send_header('Location', self.server.other_base + '/declared'); self.end_headers(); return
        if path in ['/redirect', '/redirect-cross', '/loop']:
            self.send_response(302)
            self.send_header('Location', '/declared' if path == '/redirect' else '/loop' if path == '/loop' else 'http://localhost:%d/declared' % self.server.server_port)
            self.end_headers(); return
        if path == '/auth':
            self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="synthetic icon"'); self.end_headers(); return
        if path == '/huge-page' or path == '/icon-huge':
            self.send_response(200); self.send_header('Content-Type', 'text/html' if path == '/huge-page' else 'image/png'); self.send_header('Content-Length', '1000001'); self.end_headers(); return
        if path in ['/icons/site.ico', '/favicon.ico']:
            content, mime = ico, 'image/x-icon'
        elif path == '/declared':
            content, mime = b'<html><head><link rel="shortcut icon" href="/icons/site.ico"></head></html>', 'text/html'
        elif path == '/large-icon':
            content, mime = b'<link rel="icon" href="/icon-huge"><link rel="apple-touch-icon" href="/icons/site.ico">', 'text/html'
        elif path == '/bad-page':
            content, mime = b'{}', 'application/json'
        elif path == '/bad-image':
            content, mime = b'not an image', 'image/png'
        elif path == '/stream':
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            try: self.wfile.write(b'x' * 1000100)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        elif path == '/slow':
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            try:
                self.wfile.write(b'<html>'); self.wfile.flush(); time.sleep(3); self.wfile.write(b'</html>')
            except (BrokenPipeError, ConnectionResetError): pass
            return
        else:
            content, mime = b'<html>No declared icon</html>', 'text/html'
        self.send_response(200); self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(content))); self.end_headers()
        try: self.wfile.write(content)
        except (BrokenPipeError, ConnectionResetError): pass
if __name__ == '__main__':
    serve_only = len(sys.argv) > 1 and sys.argv[1] == '--serve'
    port = int(sys.argv[2]) if serve_only else 0
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler); server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        base = 'http://127.0.0.1:%d' % server.server_port
        if serve_only:
            print(base, flush=True)
            while True: time.sleep(60)
        else:
            with tempfile.TemporaryDirectory(prefix='ssh-hub-icon-tls-') as directory:
                root = pathlib.Path(directory)
                config = root / 'openssl.cnf'
                config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=localhost\n[v3]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(config), '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
                tls_servers = []
                try:
                    for _ in range(2):
                        fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler); fixture.daemon_threads = True; fixture.tls_fixture = True
                        fixture.socket = context.wrap_socket(fixture.socket, server_side=True)
                        threading.Thread(target=fixture.serve_forever, daemon=True).start(); tls_servers.append(fixture)
                    tls_bases = ['https://127.0.0.1:%d' % fixture.server_port for fixture in tls_servers]
                    tls_servers[0].other_base = tls_bases[1]; tls_servers[1].other_base = tls_bases[0]
                    subprocess.run([sys.argv[1], base, *tls_bases], check=True)
                    assert not Handler.credentials_received, 'icon loader sent authentication or cookies'
                finally:
                    for fixture in tls_servers: fixture.shutdown(); fixture.server_close()
    finally:
        server.shutdown(); server.server_close()
