#!/usr/bin/env python3
import base64
import concurrent.futures
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
import uuid

from server import Store, SyncError, HISTORY, LEASE_SECONDS, CHUNK_LIMIT


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'data'
        self.store = Store(self.root)
        self.vault = str(uuid.uuid4())
        self.blob = b'encrypted-fixture-' * 100
        self.digest = hashlib.sha256(self.blob).hexdigest()
        self.manifest = b'opaque-manifest-fixture-' * 3

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def req(self, op, **args):
        return {'protocol': 1, 'op': op, **args}

    def call(self, op, **args):
        return self.store.request(self.req(op, vault=self.vault, **args))

    def put(self):
        return self.call('blob_put', digest=self.digest, data=base64.b64encode(self.blob).decode())

    def commit(self, expected=0):
        return self.call('commit', expected=expected, manifest=base64.b64encode(self.manifest).decode(), blobs=[self.digest])

    def error(self, code, function):
        with self.assertRaises(SyncError) as error:
            function()
        self.assertEqual(code, error.exception.code)

    def test_empty_and_roundtrip_restart(self):
        self.assertEqual(self.call('head'), {'revision': 0})
        self.error('not_found', lambda: self.call('read', revision=0))
        self.put()
        self.assertEqual(self.commit(), {'revision': 1})
        self.store.close()
        self.store = Store(self.root)
        result = self.call('read', revision=0)
        self.assertEqual(result['revision'], 1)
        self.assertEqual(base64.b64decode(result['manifest']), self.manifest)
        self.assertEqual(base64.b64decode(self.call('blob_get', digest=self.digest)['data']), self.blob)
        self.assertEqual((self.root/'sync.sqlite3').stat().st_mode & 0o777, 0o600)

    def test_cas_conflict_never_overwrites(self):
        self.put()
        self.commit()
        self.error('conflict', lambda: self.commit(0))
        self.assertEqual(self.call('head')['revision'], 1)

    def test_concurrent_writers(self):
        self.put()
        request = self.req('commit', vault=self.vault, expected=0, manifest=base64.b64encode(self.manifest).decode(), blobs=[self.digest])
        def writer(_):
            store = Store(self.root)
            try:
                try:
                    return store.request(request)['revision']
                except SyncError as error:
                    return error.code
            finally:
                store.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(writer, range(4)))
        self.assertEqual(results.count(1), 1)
        self.assertEqual(results.count('conflict'), 3)

    def test_history_and_blob_retention(self):
        self.put()
        for i in range(HISTORY + 3):
            self.commit(i)
        history = self.call('history')['history']
        self.assertEqual(len(history), HISTORY)
        self.assertEqual(history[0]['revision'], HISTORY + 3)
        self.error('not_found', lambda: self.call('read', revision=1))
        self.assertEqual(self.call('blob_get', digest=self.digest)['digest'], self.digest)

    def test_missing_invalid_and_cross_vault(self):
        self.error('missing_blob', lambda: self.commit())
        self.error('digest_mismatch', lambda: self.call('blob_put', digest='0'*64, data=base64.b64encode(self.blob).decode()))
        self.error('invalid_base64', lambda: self.call('blob_put', digest=self.digest, data='!invalid'))
        self.error('invalid_digest', lambda: self.call('blob_get', digest='../config'))
        self.error('invalid_revision', lambda: self.commit(True))
        self.error('invalid_revision', lambda: self.commit(-1))
        self.error('invalid_request', lambda: self.store.request(self.req('status', path='/etc/passwd')))
        self.error('unsupported_protocol', lambda: self.store.request({'protocol': True, 'op': 'status'}))
        self.error('invalid_vault', lambda: self.store.request(self.req('head', vault='../data')))
        self.put()
        self.error('not_found', lambda: self.store.request(self.req('blob_get', vault=str(uuid.uuid4()), digest=self.digest)))

    def test_quota_and_size(self):
        self.store.quota = len(self.blob) - 1
        self.error('quota_exceeded', self.put)
        self.assertEqual(self.store.used(), 0)
        self.error('invalid_size', lambda: self.call('blob_put', digest=self.digest, data='x'*(CHUNK_LIMIT*2)))

    def test_garbage_lease_keeps_pending_and_history(self):
        self.put()
        self.store.collect(int(time.time()))
        self.assertEqual(self.call('blob_get', digest=self.digest)['digest'], self.digest)
        self.commit()
        self.store.collect(int(time.time()) + LEASE_SECONDS + 1)
        self.assertEqual(self.call('blob_get', digest=self.digest)['digest'], self.digest)
        other = b'abandoned-encrypted-chunk'*10
        name = hashlib.sha256(other).hexdigest()
        self.call('blob_put', digest=name, data=base64.b64encode(other).decode())
        self.store.collect(int(time.time()) + LEASE_SECONDS + 1)
        self.error('not_found', lambda: self.call('blob_get', digest=name))

    def test_symlink_rejected(self):
        other = Path(self.temp.name)/'link'
        other.symlink_to(self.root, target_is_directory=True)
        self.error('storage_unavailable', lambda: Store(other))

    def test_online_backup(self):
        from backup import backup
        self.put(); self.commit()
        destination = Path(self.temp.name)/'backups'
        destination.mkdir(mode=0o700)
        backup(self.root/'sync.sqlite3', destination)
        db = sqlite3.connect(destination/'latest.sqlite3')
        try:
            self.assertEqual(db.execute('PRAGMA quick_check').fetchone(), ('ok',))
            self.assertEqual(db.execute('SELECT revision FROM heads WHERE vault=?', (self.vault,)).fetchone(), (1,))
        finally:
            db.close()
        self.assertEqual((destination/'latest.sqlite3').stat().st_mode & 0o777, 0o600)

    def test_encrypted_snapshot_secrets_and_tampering(self):
        import crypto
        from cryptography.exceptions import InvalidTag
        plaintext = json.dumps({'password': 'owned-test-password', 'totp': 'JBSWY3DPEHPK3PXP', 'records': ['fixture']}).encode()
        password = 'owned-test-vault-passphrase'
        manifest, chunks = crypto.seal(plaintext, password, self.vault)
        for name, data in chunks:
            self.call('blob_put', digest=name, data=base64.b64encode(data).decode())
        self.call('commit', expected=0, manifest=base64.b64encode(manifest).decode(), blobs=[n for n, _ in chunks])
        response = self.call('read', revision=0)
        received = {name: base64.b64decode(self.call('blob_get', digest=name)['data']) for name in response['blobs']}
        self.assertEqual(crypto.unseal(base64.b64decode(response['manifest']), received, password, self.vault), plaintext)
        database = (self.root/'sync.sqlite3').read_bytes()
        self.assertNotIn(b'owned-test-password', database)
        self.assertNotIn(b'JBSWY3DPEHPK3PXP', database)
        self.assertNotIn(password.encode(), database)
        with self.assertRaises(InvalidTag):
            crypto.unseal(manifest, received, 'wrong-test-passphrase', self.vault)
        with self.assertRaises(InvalidTag):
            crypto.unseal(manifest, received, password, str(uuid.uuid4()))
        altered = bytearray(manifest); altered[-1] ^= 1
        with self.assertRaises(InvalidTag):
            crypto.unseal(bytes(altered), received, password, self.vault)
        broken = dict(received); name = next(iter(broken)); broken[name] = b'wrong'*100
        with self.assertRaises(ValueError):
            crypto.unseal(manifest, broken, password, self.vault)

    def test_small_snapshot(self):
        import crypto
        manifest, chunks = crypto.seal(b'x', 'owned-test-vault-passphrase', self.vault)
        for name, data in chunks:
            self.call('blob_put', digest=name, data=base64.b64encode(data).decode())
        self.assertEqual(crypto.unseal(manifest, dict(chunks), 'owned-test-vault-passphrase', self.vault), b'x')

    def test_replayed_manifest_cannot_claim_new_revision(self):
        import crypto
        from client import Remote
        manifest, chunks = crypto.seal(b'owned-fixture', 'owned-test-vault-passphrase', self.vault)
        response = {'revision': 2, 'head': 2, 'manifest': base64.b64encode(manifest).decode(), 'blobs': [n for n, _ in chunks]}
        remote = Remote('fixture.invalid')
        remote.request = lambda *args, **kwargs: response
        with self.assertRaisesRegex(ValueError, 'rollback'):
            remote.pull('owned-test-vault-passphrase', self.vault)


if __name__ == '__main__':
    unittest.main()
