"""Administration, additive upgrades and browser isolation on owned fixtures only."""
import base64
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import sqlite3
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from accounts import Accounts, AuthError
from cloud import CloudServer
from dashboard import storage


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ssh-hub-web-owned-')
        self.root = Path(self.temp.name)
        self.accounts = Accounts(self.root)
        self.password = 'owned-administration-test-password'
        self.owner = self.accounts.create('owner', self.password, 'admin')
        self.alice = self.accounts.create('alice', self.password)
        self.bob = self.accounts.create('bob', self.password)
        self.owner_token = self.accounts.login('owner', self.password, 'Owned browser', kind='web')['token']
        self.alice_token = self.accounts.login('alice', self.password, 'Owned Mac')['token']
        self.bob_token = self.accounts.login('bob', self.password)['token']
        self.server = CloudServer(('127.0.0.1', 0), root=self.root)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.accounts.close(); self.temp.cleanup()

    def request(self, path, value=None, token=None, headers=None, raw=False):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=10)
        h = {'Content-Type': 'application/json'}
        if token: h['Authorization'] = 'Bearer '+token
        h.update(headers or {})
        connection.request('GET' if value is None else 'POST', path, body=json.dumps(value) if value is not None else None, headers=h)
        response = connection.getresponse(); status = response.status; result_headers = dict(response.getheaders()); body = response.read(); connection.close()
        return status, body if raw else json.loads(body), result_headers

    def dashboard(self, token=None, admin=False):
        status, body, _ = self.request('/api/admin/dashboard' if admin else '/api/v1/dashboard', token=token or self.owner_token)
        self.assertEqual(status, 200); return body

    def rpc(self, op, **values):
        return self.request('/api/v1/rpc', {'protocol':1,'op':op,'vault':self.alice['vault'],**values}, self.alice_token)

    def test_static_assets_csp_no_signup_and_scoped_dashboard(self):
        for path, mime in [('/', 'text/html'),('/assets/app.js','text/javascript'),('/assets/app.css','text/css')]:
            status, body, headers = self.request(path, raw=True)
            self.assertEqual(status, 200); self.assertIn(mime, headers['Content-Type'])
            self.assertNotIn('unsafe-inline', headers['Content-Security-Policy'])
        self.assertEqual(self.request('/assets/../accounts.py')[0], 401)
        self.assertEqual(self.request('/api/admin/dashboard')[0], 401)
        self.assertEqual(self.request('/api/admin/dashboard', token=self.alice_token)[0], 403)
        self.assertEqual(self.request('/api/v1/register', {'username':'public','password':self.password})[0], 404)
        before = set(self.root.glob('users/*'))
        own = self.dashboard(self.alice_token)
        self.assertEqual([u['username'] for u in own['users']], ['alice'])
        self.assertEqual({d['username'] for d in own['devices']}, {'alice'})
        encoded = json.dumps(own)
        for private in [self.owner['id'],self.bob['id'],self.owner_token,self.alice_token,'digest','password','salt']:
            self.assertNotIn(private, encoded)
        self.assertNotIn('server', own); self.assertEqual(set(self.root.glob('users/*')), before)
        self.assertEqual(self.dashboard(admin=True)['summary']['users'], 3)

    def test_existing_protocol_stats_encrypted_storage_and_no_plaintext(self):
        payload = b'opaque-owned-ciphertext-fixture'*3; name = hashlib.sha256(payload).hexdigest()
        self.assertTrue(self.rpc('blob_put', digest=name, data=base64.b64encode(payload).decode())[1]['ok'])
        self.assertTrue(self.rpc('commit', expected=0, manifest=base64.b64encode(b'opaque-manifest-fixture'*3).decode(), blobs=[name])[1]['ok'])
        self.assertEqual(self.rpc('read', revision=0)[1]['result']['revision'], 1)
        self.assertFalse(self.rpc('commit', expected=0, manifest=base64.b64encode(b'opaque-manifest-fixture'*3).decode(), blobs=[name])[1]['ok'])
        own = self.dashboard(self.alice_token); summary = own['summary']
        self.assertEqual(summary['requests'], 4); self.assertEqual(summary['pushes'], 1); self.assertEqual(summary['pulls'], 1); self.assertEqual(summary['errors'], 1)
        self.assertGreater(summary['uploaded'], 0); self.assertGreater(summary['downloaded'], 0)
        self.assertEqual(own['users'][0]['revision'], 1); self.assertEqual(len(own['history']), 1)
        self.assertEqual(own['history'][0]['bytes'],len(payload)+len(b'opaque-manifest-fixture'*3))
        self.assertNotIn('opaque-owned',json.dumps(own)); self.assertNotIn('opaque-manifest',json.dumps(own))
        self.assertEqual({e['action'] for e in own['activity']} & {'sync_push','sync_pull','sync_error'}, {'sync_push','sync_pull','sync_error'})
        self.assertTrue(next(d for d in own['devices'] if d['current'])['lastSync'])

    def test_device_grouping_rename_revocation_and_other_user_isolation(self):
        stable = str(uuid.uuid4())
        one = self.accounts.login('alice',self.password,'Owned second Mac',client_id=stable)['token']
        two = self.accounts.login('alice',self.password,'Owned second Mac',client_id=stable)['token']
        devices = self.dashboard(self.alice_token)['devices']; grouped = next(d for d in devices if d['name']=='Owned second Mac')
        self.assertEqual(grouped['sessions'], 2)
        self.assertEqual(self.request('/api/v1/devices/revoke', {'id':grouped['id']}, self.bob_token)[0], 400)
        self.assertEqual(self.request('/api/v1/devices/rename', {'id':grouped['id']}, self.alice_token)[0], 400)
        self.assertEqual(self.request('/api/v1/devices/rename', {'id':grouped['id'],'name':'<script>owned</script>'}, self.alice_token)[0], 200)
        self.assertEqual(self.request('/api/v1/devices/revoke', {'id':grouped['id']}, self.owner_token)[0], 200)
        for token in [one,two]:
            with self.assertRaises(AuthError): self.accounts.authenticate(token)
        self.accounts.authenticate(self.alice_token); self.accounts.authenticate(self.bob_token)
        self.assertEqual(next(d for d in self.dashboard(self.alice_token)['devices'] if d['id']==grouped['id'])['sessions'], 0)

    def test_admin_role_password_reset_enable_and_last_admin(self):
        self.assertEqual(self.request('/api/admin/users/role', {'id':self.bob['id'],'role':'admin'}, self.alice_token)[0], 403)
        self.assertEqual(self.request('/api/admin/users/role', {'id':self.owner['id'],'role':'user'}, self.owner_token)[0], 400)
        with self.assertRaisesRegex(AuthError,'last_admin'): self.accounts.set_role(self.owner['id'],'user',self.alice['id'])
        self.assertEqual(self.request('/api/admin/users/role', {'id':self.alice['id'],'role':'admin'}, self.owner_token)[0], 200)
        self.assertEqual(self.request('/api/v1/me',token=self.alice_token)[0], 401)
        fresh=self.accounts.login('alice',self.password)['token']
        self.assertEqual(self.request('/api/admin/dashboard',token=fresh)[0], 200)
        self.assertEqual(self.request('/api/admin/users/enable', {'id':self.alice['id'],'enabled':False}, self.owner_token)[0], 200)
        self.assertEqual(self.request('/api/v1/me',token=fresh)[0], 401)
        self.assertEqual(self.request('/api/admin/users/password', {'id':self.bob['id'],'password':'changed-owned-cloud-password'}, self.owner_token)[0], 200)
        self.assertEqual(self.request('/api/v1/me',token=self.bob_token)[0], 401)
        self.assertTrue(self.accounts.login('bob','changed-owned-cloud-password')['token'])

    def test_cookie_writes_require_csrf_and_browser_tokens_are_not_returned(self):
        status, body, headers = self.request('/api/v1/login', {'username':'alice','password':self.password,'device':'Owned browser','deviceId':str(uuid.uuid4())}, headers={'Origin':self.server.origin})
        self.assertEqual(status,200);self.assertNotIn('token',body)
        cookie=headers['Set-Cookie'].split(';')[0]
        self.assertEqual(self.request('/api/v1/sessions/revoke',{},headers={'Cookie':cookie})[0],400)
        _, user, _=self.request('/api/v1/me',headers={'Cookie':cookie})
        safe={'Cookie':cookie,'Origin':self.server.origin,'X-SSH-Hub-CSRF':user['csrf']}
        self.assertEqual(self.request('/api/v1/password',{'currentPassword':self.password,'password':'new-owned-cloud-password'},headers=safe)[0],200)
        self.assertEqual(self.request('/api/v1/me',headers={'Cookie':cookie})[0],401)
        self.assertEqual(self.request('/api/v1/me',token=self.alice_token)[0],401)
        self.assertTrue(self.accounts.login('alice','new-owned-cloud-password')['token'])

    def test_failed_statistics_write_does_not_break_committed_sync(self):
        payload=b'owned-opaque-ciphertext'*3; name=hashlib.sha256(payload).hexdigest()
        self.rpc('blob_put',digest=name,data=base64.b64encode(payload).decode())
        with patch.object(Accounts,'record_sync',side_effect=sqlite3.OperationalError('owned fixture full')):
            result=self.rpc('commit',expected=0,manifest=base64.b64encode(b'owned-opaque-manifest'*3).decode(),blobs=[name])
            self.assertEqual(result[0],200);self.assertTrue(result[1]['ok'])
        self.assertEqual(self.rpc('head')[1]['result']['revision'],1)

    def test_stale_password_change_cannot_overwrite_admin_reset(self):
        old=self.accounts.db.execute('SELECT password FROM users WHERE id=?',(self.alice['id'],)).fetchone()[0]
        self.accounts.reset_password('alice','owned-administrator-new-password')
        with self.assertRaisesRegex(AuthError,'invalid_credentials'):
            self.accounts.reset_password('alice','owned-stale-new-password',actor=self.alice['id'],expected_hash=old)
        self.assertTrue(self.accounts.login('alice','owned-administrator-new-password')['token'])


class UpgradeTests(unittest.TestCase):
    def test_original_sessions_and_account_records_survive_idempotent_upgrade(self):
        with tempfile.TemporaryDirectory(prefix='ssh-hub-legacy-owned-') as root:
            root=Path(root);db=sqlite3.connect(root/'accounts.sqlite3')
            db.executescript('''CREATE TABLE users(id TEXT PRIMARY KEY,username TEXT UNIQUE NOT NULL,salt BLOB NOT NULL,password BLOB NOT NULL,role TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1,vault TEXT UNIQUE NOT NULL,created INTEGER NOT NULL);
              CREATE TABLE sessions(digest TEXT PRIMARY KEY,user_id TEXT NOT NULL,expires INTEGER NOT NULL,created INTEGER NOT NULL,device TEXT NOT NULL);''')
            user,vault,token=str(uuid.uuid4()),str(uuid.uuid4()),secrets.token_urlsafe(32)
            row=(user,'owned',b'owned-salt',b'owned-existing-hash','admin',1,vault,int(time.time())-60)
            db.execute('INSERT INTO users VALUES(?,?,?,?,?,?,?,?)',row)
            db.execute('INSERT INTO sessions VALUES(?,?,?,?,?)',(Accounts.digest(token),user,int(time.time())+600,int(time.time())-60,'SSH Hub · macOS'));db.commit();db.close()
            for _ in range(2):
                accounts=Accounts(root)
                self.assertEqual(accounts.authenticate(token)['id'],user)
                self.assertEqual(accounts.db.execute('SELECT * FROM users').fetchone(),row)
                self.assertEqual(len(accounts.devices(user,token)),1);self.assertTrue(accounts.devices(user,token)[0]['current'])
                self.assertEqual(accounts.statistics(user),[]);accounts.close()

    def test_statistics_reject_symlinks_without_creating_databases(self):
        with tempfile.TemporaryDirectory(prefix='ssh-hub-metadata-owned-') as folder:
            root=Path(folder);user={'id':str(uuid.uuid4()),'vault':str(uuid.uuid4())}
            self.assertEqual(storage(root,user)['bytes'],0);self.assertFalse((root/'users').exists())
            target=root/'owned-outside';target.mkdir();(target/'sync.sqlite3').write_bytes(b'owned')
            (root/'users').mkdir();(root/'users'/user['id']).symlink_to(target,target_is_directory=True)
            with self.assertRaises(ValueError): storage(root,user)


if __name__=='__main__':unittest.main()
