"""Owned temporary account stores, synthetic passwords; no production credentials."""
import hashlib
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest

from accounts import Accounts, AuthError
from cloud import CloudServer


class CloudTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='ssh-hub-owned-cloud-test-')
        cls.root = Path(cls.temporary.name)
        cls.accounts = Accounts(cls.root)
        cls.password = 'owned-synthetic-cloud-password'
        cls.admin = cls.accounts.create('owner', cls.password, 'admin')
        cls.user = cls.accounts.create('fixture', cls.password)
        cls.other = cls.accounts.create('other', cls.password)
        cls.admin_token = cls.accounts.login('owner', cls.password)['token']
        cls.token = cls.accounts.login('fixture', cls.password)['token']
        cls.server = CloudServer(('127.0.0.1', 0), root=cls.root)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()
        cls.accounts.close(); cls.temporary.cleanup()

    def request(self, path, value=None, token=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=10)
        request_headers = {'Content-Type': 'application/json'}
        if token:
            request_headers['Authorization'] = 'Bearer '+token
        request_headers.update(headers or {})
        connection.request('GET' if value is None else 'POST', path, body=None if value is None else json.dumps(value), headers=request_headers)
        result = connection.getresponse(); status = result.status; response_headers = dict(result.getheaders()); raw = result.read(); connection.close()
        return status, json.loads(raw), response_headers

    def test_admin_only_provisioning_and_no_registration(self):
        self.assertEqual(self.request('/api/v1/register', {'username':'intruder','password':self.password})[0], 404)
        self.assertEqual(self.request('/api/admin/users', {'username':'denied','password':self.password}, self.token)[0], 403)
        status, user, _ = self.request('/api/admin/users', {'username':'created','password':self.password,'role':'admin'}, self.admin_token)
        self.assertEqual(status, 201); self.assertEqual(user['role'], 'user')
        self.assertEqual(self.request('/api/admin/users')[0], 401)
        status, users, _ = self.request('/api/admin/users', token=self.admin_token)
        self.assertEqual(status, 200)
        self.assertTrue(all(set(user) == {'id','username','role','enabled','created'} for user in users['users']))

    def test_vault_bound_to_authenticated_account(self):
        status, _, _ = self.request('/api/v1/rpc', {'protocol':1,'op':'head','vault':self.other['vault']}, self.token)
        self.assertEqual(status, 403)
        status, result, _ = self.request('/api/v1/rpc', {'protocol':1,'op':'head','vault':self.user['vault']}, self.token)
        self.assertEqual(status, 200); self.assertEqual(result['result']['revision'], 0)
        self.assertFalse((self.root/'users'/self.other['id']).exists())

    def test_cookie_csrf_and_origin(self):
        cookie = {'Cookie':'ssh_hub_session='+self.admin_token}
        self.assertEqual(self.request('/api/admin/users/enable', {'id':self.user['id'],'enabled':False}, headers=cookie)[0], 400)
        headers = {**cookie,'Origin':self.server.origin,'X-SSH-Hub-CSRF':hashlib.sha256(('csrf:'+self.admin_token).encode()).hexdigest()}
        # The owner cannot disable their own account, even with valid CSRF.
        self.assertEqual(self.request('/api/admin/users/enable', {'id':self.admin['id'],'enabled':False}, headers=headers)[0], 400)
        self.assertEqual(self.request('/api/v1/login', {'username':'owner','password':self.password}, headers={'Origin':'https://foreign.invalid'})[0], 403)

    def test_disable_and_password_reset_revoke_sessions(self):
        account = self.accounts.create('revocation', self.password)
        token = self.accounts.login('revocation', self.password)['token']
        self.accounts.enable(account['id'], False, self.admin['id'])
        with self.assertRaises(AuthError): self.accounts.authenticate(token)
        self.accounts.enable(account['id'], True, self.admin['id'])
        token = self.accounts.login('revocation', self.password)['token']
        self.accounts.reset_password('revocation', 'changed-owned-synthetic-password')
        with self.assertRaises(AuthError): self.accounts.authenticate(token)
        self.assertNotIn(token.encode(), (self.root/'accounts.sqlite3').read_bytes())
        self.assertNotIn(self.password.encode(), (self.root/'accounts.sqlite3').read_bytes())

    def test_login_cookie_logout_and_limits(self):
        status, result, headers = self.request('/api/v1/login', {'username':'fixture','password':self.password})
        self.assertEqual(status, 200)
        self.assertIn('HttpOnly', headers['Set-Cookie']); self.assertIn('Secure', headers['Set-Cookie']); self.assertIn('SameSite=Strict', headers['Set-Cookie'])
        self.assertEqual(self.request('/api/v1/logout', {}, result['token'])[0], 200)
        self.assertEqual(self.request('/api/v1/me', token=result['token'])[0], 401)
        for _ in range(5):
            with self.assertRaises(AuthError): self.accounts.login('nonexistent', self.password)
        with self.assertRaisesRegex(AuthError, 'try_later'): self.accounts.login('nonexistent', self.password)
        with self.assertRaises(AuthError): self.accounts.create('../escape', self.password)
        with self.assertRaises(AuthError): self.accounts.create('short-password', 'short')
