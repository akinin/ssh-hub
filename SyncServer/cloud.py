#!/usr/bin/env python3
"""Private HTTP upstream for NPM's HTTPS virtual host. No registration API."""
from collections import defaultdict
import fcntl
import hashlib
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import socket
import sqlite3
import threading
import time

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))

from accounts import Accounts, AuthError
from server import Store, SyncError, REQUEST_LIMIT

ROOT = Path('/var/lib/ssh-hub-sync/cloud')
USER_QUOTA = 512 * 1024**2
TOTAL_QUOTA = 2 * 1024**3


class CloudServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, root=ROOT, origin='https://ssh-hub.olshaniki.com', proxy='10.10.100.10'):
        self.root, self.origin, self.proxy = Path(root), origin, proxy
        self.workers = threading.BoundedSemaphore(8)
        self.login_workers = threading.BoundedSemaphore(2)
        self.rate_lock = threading.Lock()
        self.attempts = {}
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        Accounts(self.root).close()
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.workers.acquire(blocking=False):
            request.close(); return
        try:
            super().process_request(request, address)
        except BaseException:
            self.workers.release(); raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.workers.release()

    def login_allowed(self, address):
        with self.rate_lock:
            now = time.monotonic()
            self.attempts = {k: [t for t in v if t > now-60] for k,v in self.attempts.items() if any(t > now-60 for t in v)}
            if address not in self.attempts and len(self.attempts) >= 1024:
                return False
            times = self.attempts.setdefault(address, [])
            if len(times) >= 10:
                return False
            times.append(now); return True


class Handler(BaseHTTPRequestHandler):
    server_version = 'SSHHubSync'
    sys_version = ''
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup(); self.connection.settimeout(30)

    def log_message(self, *args):
        pass  # Never log headers, bodies, usernames, passwords or session tokens.

    def respond(self, code, value, cookie=None, html=False):
        data = value if html else json.dumps(value, separators=(',', ':')).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'text/html; charset=utf-8' if html else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'")
        self.send_header('Connection', 'close')
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers(); self.wfile.write(data); self.close_connection = True

    def fail(self, status, code):
        self.respond(status, {'error': code})

    def trusted(self):
        peer = self.client_address[0]
        return ipaddress.ip_address(peer).is_loopback or (peer == self.server.proxy and self.headers.get('X-Forwarded-Proto') == 'https')

    def body(self):
        if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
            raise SyncError('invalid_request')
        try:
            size = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            raise SyncError('invalid_size') from None
        if not 1 <= size <= REQUEST_LIMIT:
            raise SyncError('invalid_size')
        raw = self.rfile.read(size)
        if len(raw) != size:
            raise SyncError('invalid_size')
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            raise SyncError('invalid_json') from None
        if not isinstance(result, dict):
            raise SyncError('invalid_request')
        return result

    def authenticate(self, accounts, write=False):
        authorization = self.headers.get('Authorization', '')
        if authorization.startswith('Bearer '):
            token = authorization[7:]
        else:
            jar = cookies.SimpleCookie()
            try:
                jar.load(self.headers.get('Cookie', ''))
                token = jar['ssh_hub_session'].value
            except (KeyError, cookies.CookieError):
                raise AuthError('unauthorized') from None
            if write and (self.headers.get('Origin') != self.server.origin or self.headers.get('X-SSH-Hub-CSRF') != hashlib.sha256(('csrf:'+token).encode()).hexdigest()):
                raise AuthError('csrf')
        return token, accounts.authenticate(token)

    def do_GET(self):
        if not self.trusted():
            self.fail(403, 'proxy_required'); return
        if self.path == '/':
            self.respond(200, Path(__file__).with_name('index.html').read_bytes(), html=True); return
        if self.path == '/health':
            self.respond(200, {'status': 'ok', 'protocol': 1, 'registration': False}); return
        accounts = Accounts(self.server.root)
        try:
            token, user = self.authenticate(accounts)
            if self.path == '/api/v1/me':
                self.respond(200, {**user, 'csrf': hashlib.sha256(('csrf:'+token).encode()).hexdigest()})
            elif self.path == '/api/admin/users' and user['role'] == 'admin':
                self.respond(200, {'users': accounts.list()})
            else:
                self.fail(404, 'not_found')
        except AuthError:
            self.fail(401, 'unauthorized')
        finally:
            accounts.close()

    def do_POST(self):
        if not self.trusted():
            self.fail(403, 'proxy_required'); return
        if self.headers.get('Origin') not in (None, self.server.origin):
            self.fail(403, 'origin'); return
        accounts = Accounts(self.server.root)
        try:
            value = self.body()
            if self.path == '/api/v1/login':
                if not self.server.login_allowed(self.client_address[0]) or not self.server.login_workers.acquire(blocking=False):
                    self.fail(429, 'try_later'); return
                try:
                    result = accounts.login(value.get('username'), value.get('password'), value.get('device', 'SSH Hub'))
                finally:
                    self.server.login_workers.release()
                self.respond(200, result, cookie='ssh_hub_session='+result['token']+'; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000')
                return
            # Unknown endpoints include /register: provisioning is admin-only.
            if self.path not in ('/api/v1/logout', '/api/v1/rpc', '/api/admin/users', '/api/admin/users/enable'):
                self.fail(404, 'not_found'); return
            token, user = self.authenticate(accounts, write=True)
            if self.path == '/api/v1/logout':
                accounts.logout(token)
                self.respond(200, {'ok': True}, cookie='ssh_hub_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0')
            elif self.path == '/api/v1/rpc':
                if value.get('op') != 'status' and value.get('vault') != user['vault']:
                    self.fail(403, 'vault_forbidden'); return
                with (self.server.root/'.quota.lock').open('a') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    if value.get('op') in ('blob_put', 'commit'):
                        total = sum(p.stat().st_size for p in (self.server.root/'users').glob('*/sync.sqlite3'))
                        if total > TOTAL_QUOTA - 8*1024**2:
                            raise SyncError('quota_exceeded')
                    store = Store(self.server.root/'users'/user['id'], quota=USER_QUOTA)
                    try:
                        result = store.request(value)
                    except SyncError as error:
                        self.respond(200, {'ok': False, 'protocol': 1, 'error': error.code}); return
                    finally:
                        store.close()
                self.respond(200, {'ok': True, 'protocol': 1, 'result': result})
            elif user['role'] != 'admin':
                self.fail(403, 'admin_required')
            elif self.path == '/api/admin/users':
                self.respond(201, accounts.create(value.get('username'), value.get('password')))
            else:
                accounts.enable(value.get('id'), value.get('enabled'), user['id'])
                self.respond(200, {'ok': True})
        except AuthError as error:
            code = str(error)
            self.fail(429 if code == 'try_later' else 401 if code in ('invalid_credentials', 'unauthorized') else 400, code)
        except SyncError as error:
            self.fail(400, error.code)
        except sqlite3.Error:
            self.fail(503, 'storage_unavailable')
        except (ValueError, TypeError, OSError):
            self.fail(400, 'invalid_request')
        finally:
            accounts.close()


if __name__ == '__main__':
    os.umask(0o077)
    server = CloudServer(('0.0.0.0', 8788), origin=os.environ.get('SSH_HUB_SYNC_ORIGIN', 'https://ssh-hub.olshaniki.com'), proxy=os.environ.get('SSH_HUB_SYNC_PROXY', '10.10.100.10'))
    server.serve_forever()
