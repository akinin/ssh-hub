"""Owned HTTP fixtures only; never queries a user's CVEs or servers."""
import http.server
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        assert not self.headers.get('Cookie') and not self.headers.get('Authorization')
        requests.append(self.path)
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/must-not-follow')
            self.end_headers()
            return
        if self.path == '/limited':
            self.send_response(429)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        try:
            if self.path == '/overflow':
                for _ in range(256):
                    self.wfile.write(b'x' * 65536)
            elif self.path == '/slow':
                time.sleep(2)
                self.wfile.write(b'late')
            else:
                self.wfile.write(b'{"fixture":true}')
        except (BrokenPipeError, ConnectionResetError):
            pass


with tempfile.TemporaryDirectory(prefix='security-intel-http-') as folder:
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for path, mode in [('/ok', 'success'), ('/redirect', 'error'), ('/limited', 'error'), ('/overflow', 'error'), ('/slow', 'cancel')]:
            output = pathlib.Path(folder) / 'reply.json'
            start = time.monotonic()
            subprocess.run([sys.argv[1], '--download', 'http://127.0.0.1:' + str(server.server_port) + path, mode, str(output)], check=True, timeout=8)
            if mode == 'cancel':
                assert time.monotonic() - start < 2
        assert '/must-not-follow' not in requests
    finally:
        server.shutdown()
        server.server_close()
print('PASS intelligence transport: bounded streamed body, no redirects/credentials/cookies, HTTP failure and cancellation')
