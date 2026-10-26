#!/usr/bin/env python3
"""Read-only router APIs against disposable loopback fixtures, never user devices."""
import base64
import hashlib
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

PASSWORD = 'NOT-A-REAL-ROUTER-PASSWORD'
SESSION = 'DISPOSABLE-KEENETIC-SESSION'
BASIC = 'Basic ' + base64.b64encode(('fixture:' + PASSWORD).encode()).decode()
ANSWER = hashlib.sha256(('FIXTURE-CHALLENGE' + hashlib.md5(('fixture:Fixture Keenetic:' + PASSWORD).encode()).hexdigest()).encode()).hexdigest()

INTERFACES = [
    {'.id': '*1', 'name': 'ether1', 'type': 'ether', 'mac-address': '02:00:00:00:00:01', 'running': 'true', 'disabled': 'false', 'rx-byte': '18446744073709551614', 'tx-byte': '2000'},
    {'.id': '*2', 'name': 'ether2', 'type': 'ether', 'mac-address': '02:00:00:00:00:02', 'running': 'false', 'disabled': 'false'},
    {'.id': '*3', 'name': 'ether3', 'type': 'ether', 'mac-address': '02:00:00:00:00:03', 'running': 'true', 'disabled': 'false'}]
ADDRESSES = [dict(address='203.0.113.10/24', interface='ether1'), dict(address='198.51.100.10/24', interface='ether2')]
ROUTES = [
    {'dst-address': '0.0.0.0/0', 'gateway': '203.0.113.1', 'immediate-gw': '203.0.113.1%ether1', 'active': 'true'},
    {'dst-address': '0.0.0.0/0', 'gateway': '198.51.100.1', 'immediate-gw': '198.51.100.1%ether2', 'active': 'false'}]
KEENETIC_INTERFACES = {
    'GigabitEthernet0': {'id': 'GigabitEthernet0', 'type': 'GigabitEthernet', 'link': 'up', 'interface-name': 'LAN', 'port': {
        '1': {'id': 'GigabitEthernet0/0', 'type': 'Port', 'link': 'up', 'speed': '1000', 'interface-name': '1'},
        '2': {'id': 'GigabitEthernet0/1', 'type': 'Port', 'link': 'down', 'speed': '1000', 'interface-name': '2'}}},
    'GigabitEthernet1': {'id': 'GigabitEthernet1', 'type': 'GigabitEthernet', 'link': 'up', 'state': 'up', 'interface-name': 'ISP', 'address': '203.0.113.10', 'mac': '02:00:00:00:00:01'},
    'UsbLte0': {'id': 'UsbLte0', 'type': 'UsbLte', 'link': 'up', 'interface-name': 'LTE', 'address': '198.51.100.10'}}


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    mode = 'normal'
    provider = 'mikrotik'
    requests = None
    forbidden_hits = 0
    cross_port = 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, value, status=200, headers=None):
        body = json.dumps(value).encode()
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

    def large(self, chunked):
        self.send_response(200)
        self.send_header('Connection', 'close')
        self.send_header('Content-Type', 'application/json')
        self.send_header('Transfer-Encoding' if chunked else 'Content-Length', 'chunked' if chunked else str(3 * 1024 * 1024))
        self.end_headers()
        try:
            for _ in range(192):
                data = b' ' * 16384
                self.wfile.write(('%x\r\n' % len(data)).encode() + data + b'\r\n' if chunked else data)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b'0\r\n\r\n')
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def do_POST(self):
        self.handle_request()

    def do_GET(self):
        self.handle_request()

    def handle_request(self):
        server = self.server
        if server.requests is None:
            server.requests = []
        server.requests.append((self.path, self.command))
        if self.path == '/must-not-receive-secrets':
            server.forbidden_hits += 1
            return self.reply({'error': 'LEAKED-SERVER-BODY'})
        parsed = urllib.parse.urlsplit(self.path)
        path, query = parsed.path, urllib.parse.parse_qs(parsed.query)
        size = int(self.headers.get('Content-Length', 0))
        assert 0 <= size <= 8192, 'bounded request body'
        body = json.loads(self.rfile.read(size)) if size else None
        mode = server.mode
        if mode in ('cancel', 'task-cancel', 'slow'):
            time.sleep(21 if mode == 'slow' else 3)
            return self.reply({})
        if mode in ('redirect', 'cross-redirect'):
            target = '/must-not-receive-secrets' if mode == 'redirect' else 'http://127.0.0.1:%d/must-not-receive-secrets' % server.cross_port
            return self.reply({'secret': PASSWORD, 'message': 'LEAKED-SERVER-BODY'}, 302, {'Location': target})
        if mode in ('oversized', 'stream-oversized'):
            return self.large(mode == 'stream-oversized')
        if mode == 'forbidden':
            return self.reply({'password': PASSWORD, 'message': 'LEAKED-SERVER-BODY'}, 403)
        if server.provider == 'mikrotik':
            assert self.headers.get('Authorization') == BASIC, 'HTTPS Basic only for RouterOS'
            assert self.headers.get('Cookie') is None, 'RouterOS uses no browser cookies'
            if mode == 'unauthorized':
                return self.reply({'message': 'LEAKED-SERVER-BODY', 'password': PASSWORD}, 401, {'WWW-Authenticate': 'Basic realm="RouterOS"'})
            paths = {
                '/rest/interface': {'.id', 'name', 'type', 'mac-address', 'running', 'disabled', 'rx-byte', 'tx-byte', 'comment'},
                '/rest/system/identity': {'name'},
                '/rest/ip/address': {'address', 'interface', 'actual-interface', 'disabled', 'invalid'},
                '/rest/ip/route': {'dst-address', 'gateway', 'immediate-gw', 'active', 'disabled', 'routing-table', 'distance'},
                '/rest/ip/dns': {'servers', 'dynamic-servers'},
                '/rest/ip/neighbor': {'identity', 'interface', 'interface-name', 'address', 'address6', 'mac-address', 'platform', 'board', 'discovered-by'},
                '/rest/interface/ethernet': {'.id', 'name'}}
            if self.command == 'POST':
                assert path == '/rest/interface/ethernet/monitor' and body and set(body) == {'numbers', 'once'} and body['once'] == '', 'only read-only one-shot Ethernet monitor is POST'
                assert body['numbers'] in ('*1', '*2', '*3')
                number = body['numbers'][-1]
                return self.reply([dict(name='ether' + number, status='no-link' if number == '2' else 'link-ok', rate='2.5Gbps' if number == '1' else '1Gbps')])
            assert path in paths and self.command == 'GET', 'fixed read-only menu'
            assert set(query.get('.proplist', [''])[0].split(',')) == paths[path], 'no full configuration or private-key fields'
            if path == '/rest/ip/route':
                assert query.get('dst-address') == ['0.0.0.0/0'], 'routes limited to defaults'
            if path == '/rest/interface':
                if mode == 'schema':
                    return self.reply({'unexpected': 'shape'})
                if mode == 'interface-cap':
                    return self.reply([dict(name='ether%d' % i, type='ether') for i in range(257)])
                return self.reply(INTERFACES)
            if path == '/rest/system/identity':
                return self.reply(dict(name=PASSWORD if mode == 'reflection' else 'Fixture Router'))
            if path == '/rest/ip/address':
                return self.reply(ADDRESSES)
            if path == '/rest/ip/route':
                return self.reply(ROUTES)
            if path == '/rest/ip/dns':
                return self.reply({'servers': '1.1.1.1,9.9.9.9', 'dynamic-servers': '2001:4860:4860::8888'})
            if path == '/rest/ip/neighbor':
                if mode == 'optional-missing':
                    return self.reply({'message': 'LEAKED-SERVER-BODY'}, 404)
                return self.reply([{'identity': 'Fixture Switch', 'interface': 'ether3', 'interface-name': 'Gi0/1', 'address': '192.0.2.2', 'mac-address': '02:00:00:00:00:12', 'discovered-by': 'lldp,cdp'}])
            if path == '/rest/interface/ethernet':
                return self.reply([{'.id': '*1', 'name': 'ether1'}, {'.id': '*2', 'name': 'ether2'}, {'.id': '*3', 'name': 'ether3'}])
        else:
            assert self.headers.get('Authorization') is None, 'no password/digest fallback for local Keenetic challenge'
            if path == '/auth' and self.command == 'GET':
                if mode == 'auth-unsupported':
                    return self.reply({}, 401, {'WWW-Authenticate': 'Digest realm="Unsupported Proxy Mode"'})
                return self.reply({}, 401, {'X-NDM-Challenge': 'FIXTURE-CHALLENGE', 'X-NDM-Realm': 'Fixture Keenetic', 'WWW-Authenticate': 'x-ndw2-interactive', 'Set-Cookie': 'session_id=%s; Path=/; SameSite=Strict' % SESSION})
            assert self.headers.get('Cookie') == 'session_id=' + SESSION, 'ephemeral same-controller cookie needed'
            if path == '/auth':
                assert self.command == 'POST' and body == {'login': 'fixture', 'password': ANSWER}, 'only hash sent to Keenetic auth'
                return self.reply({'authenticated': mode != 'unauthorized'}, 401 if mode == 'unauthorized' else 200)
            assert self.command == 'GET', 'RCI reads never POST config'
            if path == '/rci/show/interface':
                if mode == 'schema':
                    return self.reply({'unexpected': 'shape'})
                if mode == 'interface-cap':
                    return self.reply({'ether%d' % i: dict(id='ether%d' % i, type='Port') for i in range(257)})
                return self.reply(KEENETIC_INTERFACES)
            if path == '/rci/show/system':
                return self.reply({'hostname': PASSWORD if mode == 'reflection' else 'Fixture Keenetic'})
            if path == '/rci/show/ip/route':
                return self.reply({'route': [dict(destination='0.0.0.0/0', gateway='203.0.113.1', interface='ISP'), dict(destination='0.0.0.0', mask='0.0.0.0', gateway='198.51.100.1', interface='LTE')]})
            if path == '/rci/show/ip/name-server':
                return self.reply({'server': [dict(address='9.9.9.9', interface=''), dict(address='1.1.1.1', interface='ISP'), dict(address='8.8.8.8', interface='LTE')]})
            if path == '/rci/show/ip/hotspot':
                if mode == 'optional-missing':
                    return self.reply({'message': 'LEAKED-SERVER-BODY'}, 404)
                return self.reply({'host': [dict(name=PASSWORD if mode == 'reflection' else 'Fixture Client', ip='192.0.2.20', mac='02:00:00:00:00:20', active=True, interface='LAN')]})
        raise AssertionError('Unexpected fixture API request')


def run(binary, server, provider, mode, tls=False):
    server.mode, server.provider, server.requests = mode, provider, []
    result = subprocess.run([str(binary), '--integration', '%s://127.0.0.1:%d' % ('https' if tls else 'http', server.server_port), provider, mode], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, '%s %s: %s\n%s' % (provider, mode, result.stdout, result.stderr)
    assert PASSWORD not in result.stdout + result.stderr and SESSION not in result.stdout + result.stderr and BASIC not in result.stdout + result.stderr, 'no credentials in output'
    print(result.stdout.strip())


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: Tests/TopologyRouterAPIIntegrationTests.py /path/to/topology-router-api-tests (compiled -DTOPOLOGY_UNIFI_TEST)')
    binary = pathlib.Path(sys.argv[1]).resolve()
    servers, threads = [], []
    try:
        server, target = Server(('127.0.0.1', 0), Handler), Server(('127.0.0.1', 0), Handler)
        server.cross_port = target.server_port
        for item in (server, target):
            servers.append(item)
            thread = threading.Thread(target=item.serve_forever, daemon=True); thread.start(); threads.append(thread)
        for provider in ['mikrotik', 'keenetic']:
            modes = ['normal', 'reflection', 'optional-missing', 'redirect', 'cross-redirect', 'unauthorized', 'forbidden', 'oversized', 'stream-oversized', 'schema', 'interface-cap', 'cancel', 'task-cancel', 'slow']
            if provider == 'keenetic':
                modes.append('auth-unsupported')
            for mode in modes:
                run(binary, server, provider, mode)
        assert server.forbidden_hits == 0 and target.forbidden_hits == 0, 'redirect forwarded no credentials/cookies'
        with tempfile.TemporaryDirectory(prefix='ssh-hub-router-tls-') as directory:
            directory = pathlib.Path(directory)
            key, cert = directory / 'key.pem', directory / 'cert.pem'
            subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tls = Server(('127.0.0.1', 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(str(cert), str(key))
            tls.socket = context.wrap_socket(tls.socket, server_side=True)
            servers.append(tls)
            thread = threading.Thread(target=tls.serve_forever, daemon=True); thread.start(); threads.append(thread)
            for provider in ['mikrotik', 'keenetic']:
                run(binary, tls, provider, 'tls', tls=True)
                assert not tls.requests, 'untrusted TLS fails before credentials'
        print('Router API localhost integration checks passed; no user devices or credentials used')
    finally:
        for server in servers:
            server.shutdown(); server.server_close()
        for thread in threads:
            thread.join(timeout=2)


if __name__ == '__main__':
    main()
