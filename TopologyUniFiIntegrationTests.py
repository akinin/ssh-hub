#!/usr/bin/env python3
"""UniFi client checks against disposable localhost HTTP/TLS fixtures only."""
import http.server
import json
import pathlib
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

SITE = '00000000-0000-0000-0000-000000000010'
GATEWAY = '00000000-0000-0000-0000-000000000011'
DEVICE = '00000000-0000-0000-0000-000000000012'
CLIENT = '00000000-0000-0000-0000-000000000013'
KEY = 'DISPOSABLE-TEST-KEY-UNIFI-NOT-A-SECRET'


def page(rows, offset=0, total=None):
    return dict(offset=offset, limit=200, count=len(rows), totalCount=len(rows) + offset if total is None else total, data=rows)


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    mode = 'normal'
    requests = None
    forbidden_hits = 0
    cross_port = 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, payload, status=200, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def do_GET(self):
        server = self.server
        if server.requests is None:
            server.requests = []
        server.requests.append((self.path, self.headers.get('X-API-Key'), self.command))
        if self.path == '/must-not-receive-key':
            server.forbidden_hits += 1
            return self.reply({'error': 'LEAKED-SERVER-BODY'})
        assert self.headers.get('X-API-Key') == KEY, 'fixture expected a disposable API key'
        assert self.headers.get('Cookie') is None, 'cookies must not be stored or sent'
        assert self.headers.get('Authorization') is None, 'no cookie/password API fallback'
        mode = server.mode
        if mode in ('cancel', 'task-cancel', 'slow'):
            time.sleep(21 if mode == 'slow' else 3)
            return self.reply(page([], 0))
        if mode in ('redirect', 'cross-redirect'):
            target = '/must-not-receive-key' if mode == 'redirect' else 'http://127.0.0.1:%d/must-not-receive-key' % server.cross_port
            return self.reply({'secret': KEY, 'message': 'LEAKED-SERVER-BODY'}, 302, {'Location': target, 'Set-Cookie': 'secret=not-for-later'})
        if mode in ('unauthorized', 'forbidden'):
            return self.reply({'secret': KEY, 'message': 'LEAKED-SERVER-BODY'}, 401 if mode == 'unauthorized' else 403)
        if mode == 'oversized':
            self.send_response(200)
            self.send_header('Content-Length', str(3 * 1024 * 1024))
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                self.wfile.write(b' ' * (3 * 1024 * 1024))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        if mode == 'chunked-oversized':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                for _ in range(200):
                    chunk = b' ' * 16384
                    self.wfile.write(('%x\r\n' % len(chunk)).encode() + chunk + b'\r\n')
                    self.wfile.flush()
                self.wfile.write(b'0\r\n\r\n')
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        if mode == 'schema':
            return self.reply({'meta': {'rc': 'ok'}, 'data': []})
        if mode == 'page-cap':
            return self.reply(page([], total=101))
        if mode == 'bad-offset':
            return self.reply(page([dict(id=SITE, name='Fixture Site')], offset=7, total=8))
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        prefix = '/integration/v1' if mode == 'standalone' else '/proxy/network/integration/v1'
        assert path.startswith(prefix), 'wrong explicit API path'
        path = path[len(prefix):]
        query = urllib.parse.parse_qs(parsed.query)
        if path == '/sites':
            assert query.get('limit') == ['200']
            offset = int(query['offset'][0])
            if mode == 'repeated-page':
                # The second page reports the same ID with a new offset.
                return self.reply(page([dict(id=SITE, name='Fixture Site')], offset=offset, total=2))
            if offset == 0:
                return self.reply(page([dict(id=SITE, name=KEY if mode == 'reflected-key' else 'Fixture Site')], total=2), headers={'Set-Cookie': 'secret=not-for-later'})
            assert offset == 1
            return self.reply(page([dict(id='00000000-0000-0000-0000-000000000099', name='Fixture Site 2')], offset=1, total=2))
        if path == '/sites/%s/devices' % SITE:
            return self.reply(page([
                dict(id=GATEWAY, name='Gateway', ipAddress='192.0.2.1', macAddress='02:00:00:00:00:01', features=['gateway', 'switching'], interfaces=['ports'], state='ONLINE'),
                dict(id=DEVICE, name='Access Point', ipAddress='192.0.2.2', macAddress='02:00:00:00:00:02', features=['accessPoint'], interfaces=['ports', 'radios'], state='ONLINE')]))
        if path == '/sites/%s/clients' % SITE:
            return self.reply(page([dict(id=CLIENT, name=KEY if mode == 'reflected-key' else 'Fixture Client', ipAddress='192.0.2.20', macAddress='02:00:00:00:00:20', type='WIRELESS', uplinkDeviceId=DEVICE)]))
        if path.endswith('/statistics/latest'):
            if mode == 'statistics-missing':
                return self.reply({'error': 'LEAKED-SERVER-BODY'}, 404)
            return self.reply(dict(interfaces={}, uplink=dict(rxRateBps=1234567, txRateBps=7654321)))
        if path == '/sites/%s/devices/%s' % (SITE, GATEWAY):
            return self.reply(dict(id=GATEWAY, name='Gateway', ipAddress='192.0.2.1', macAddress='02:00:00:00:00:01', features={'switching': {}}, state='ONLINE', model='Fixture Gateway', interfaces={'ports': [dict(idx=1, state='UP', speedMbps=2500, maxSpeedMbps=10000, connector='RJ45')]}))
        if path == '/sites/%s/devices/%s' % (SITE, DEVICE):
            return self.reply(dict(id=DEVICE, name='Access Point', ipAddress='192.0.2.2', macAddress='02:00:00:00:00:02', features={'accessPoint': {}}, state='ONLINE', interfaces={'ports': []}, uplink=dict(deviceId=GATEWAY)))
        raise AssertionError('Unexpected read-only API path %s' % path)


def run(binary, server, mode, tls=False):
    server.mode = mode
    server.requests = []
    scheme = 'https' if tls else 'http'
    result = subprocess.run([str(binary), '--integration', '%s://127.0.0.1:%d' % (scheme, server.server_port), mode], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, '%s: %s\n%s' % (mode, result.stdout, result.stderr)
    assert KEY not in result.stdout + result.stderr, 'secret must not reach tool output'
    assert all(request[2] == 'GET' for request in server.requests), 'all endpoints must be read only'
    print(result.stdout.strip())


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: TopologyUniFiIntegrationTests.py /path/to/topology-unifi-tests (compiled with -DTOPOLOGY_UNIFI_TEST)')
    binary = pathlib.Path(sys.argv[1]).resolve()
    servers = []
    threads = []
    try:
        server = FixtureServer(('127.0.0.1', 0), Handler)
        target = FixtureServer(('127.0.0.1', 0), Handler)
        server.cross_port = target.server_port
        for item in (server, target):
            servers.append(item)
            thread = threading.Thread(target=item.serve_forever, daemon=True); thread.start(); threads.append(thread)
        for mode in ['normal', 'standalone', 'statistics-missing', 'reflected-key', 'redirect', 'cross-redirect', 'unauthorized', 'forbidden', 'oversized', 'chunked-oversized', 'schema', 'page-cap', 'bad-offset', 'repeated-page', 'cancel', 'task-cancel', 'slow']:
            run(binary, server, mode)
        assert server.forbidden_hits == 0 and target.forbidden_hits == 0, 'redirect must not forward API key'
        with tempfile.TemporaryDirectory(prefix='ssh-hub-unifi-tls-') as directory:
            directory = pathlib.Path(directory)
            key, cert = directory / 'key.pem', directory / 'cert.pem'
            subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tls = FixtureServer(('127.0.0.1', 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(str(cert), str(key))
            tls.socket = context.wrap_socket(tls.socket, server_side=True)
            servers.append(tls)
            thread = threading.Thread(target=tls.serve_forever, daemon=True); thread.start(); threads.append(thread)
            run(binary, tls, 'tls', tls=True)
            assert not tls.requests, 'untrusted certificate must fail before API key request'
        print('UniFi localhost integration checks passed; no user controller or credentials used')
    finally:
        for server in servers:
            server.shutdown(); server.server_close()
        for thread in threads:
            thread.join(timeout=2)


if __name__ == '__main__':
    main()
