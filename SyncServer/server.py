#!/usr/bin/env python3
"""SSH Hub Sync protocol 1: opaque encrypted snapshots over authenticated SSH.

One bounded JSON request per SSH session. This process never receives a vault
password or decryption key, and never executes client-supplied commands/paths.
"""
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import select
import sqlite3
import sys
import time
import uuid

PROTOCOL = 1
CHUNK_LIMIT = 4 * 1024 * 1024 + 64
MANIFEST_LIMIT = 1024 * 1024
REQUEST_LIMIT = 6 * 1024 * 1024
VAULT_LIMIT = 350_000_052
QUOTA = 2 * 1024 * 1024 * 1024
HISTORY = 20
LEASE_SECONDS = 24 * 60 * 60
MAX_BLOBS = 4096


class SyncError(Exception):
    def __init__(self, code):
        self.code = code


def identifier(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
        return value
    except (ValueError, AttributeError):
        raise SyncError('invalid_vault') from None


def digest(value):
    if not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{64}', value) is None:
        raise SyncError('invalid_digest')
    return value


def integer(value):
    if type(value) is not int or not 0 <= value < 2**53:
        raise SyncError('invalid_revision')
    return value


def decode(value, limit, minimum=32):
    if not isinstance(value, str) or len(value) > ((limit + 2) // 3) * 4:
        raise SyncError('invalid_size')
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise SyncError('invalid_base64') from None
    if not minimum <= len(data) <= limit:
        raise SyncError('invalid_size')
    return data


def encode(value):
    return base64.b64encode(value).decode('ascii')


class Store:
    def __init__(self, root, quota=QUOTA):
        self.root = Path(root)
        self.quota = quota
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.root.is_symlink() or not self.root.is_dir():
            raise SyncError('storage_unavailable')
        database = self.root / 'sync.sqlite3'
        if database.is_symlink():
            raise SyncError('storage_unavailable')
        self.db = sqlite3.connect(database, timeout=10, isolation_level=None)
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA synchronous=FULL')
        # Reserve space for bounded journals and the OS on the 8 GiB LXC disk.
        self.db.execute('PRAGMA max_page_count=786432')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS heads (
                vault TEXT PRIMARY KEY, revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS blobs (
                vault TEXT NOT NULL, digest TEXT NOT NULL, data BLOB NOT NULL,
                touched INTEGER NOT NULL, PRIMARY KEY(vault,digest));
            CREATE TABLE IF NOT EXISTS revisions (
                vault TEXT NOT NULL, revision INTEGER NOT NULL,
                manifest BLOB NOT NULL, created INTEGER NOT NULL,
                PRIMARY KEY(vault,revision));
            CREATE TABLE IF NOT EXISTS refs (
                vault TEXT NOT NULL, revision INTEGER NOT NULL, digest TEXT NOT NULL,
                PRIMARY KEY(vault,revision,digest),
                FOREIGN KEY(vault,revision) REFERENCES revisions(vault,revision) ON DELETE CASCADE,
                FOREIGN KEY(vault,digest) REFERENCES blobs(vault,digest));
        ''')
        os.chmod(database, 0o600)

    def close(self):
        self.db.close()

    def used(self):
        return self.db.execute('SELECT COALESCE(SUM(length(data)),0) FROM blobs').fetchone()[0] + self.db.execute('SELECT COALESCE(SUM(length(manifest)),0) FROM revisions').fetchone()[0]

    def collect(self, now):
        # Uploads have a 24-hour lease; retain everything referenced by history.
        self.db.execute('''DELETE FROM blobs WHERE touched < ? AND NOT EXISTS
            (SELECT 1 FROM refs WHERE refs.vault=blobs.vault AND refs.digest=blobs.digest)''', (now - LEASE_SECONDS,))

    def request(self, req):
        if not isinstance(req, dict) or req.get('protocol') != PROTOCOL or type(req.get('protocol')) is not int:
            raise SyncError('unsupported_protocol')
        op = req.get('op')
        schemas = {'status': set(), 'head': {'vault'}, 'history': {'vault'},
                   'read': {'vault', 'revision'}, 'blob_get': {'vault', 'digest'},
                   'blob_put': {'vault', 'digest', 'data'},
                   'commit': {'vault', 'expected', 'manifest', 'blobs'}}
        if not isinstance(op, str) or op not in schemas or set(req) != schemas[op] | {'op', 'protocol'}:
            raise SyncError('invalid_request')
        if op == 'status':
            return {'protocol': PROTOCOL, 'chunkLimit': CHUNK_LIMIT, 'manifestLimit': MANIFEST_LIMIT,
                    'vaultLimit': VAULT_LIMIT, 'quotaBytes': self.quota, 'historyLimit': HISTORY}
        vault = identifier(req['vault'])
        now = int(time.time())
        self.db.execute('BEGIN IMMEDIATE' if op in ('commit', 'blob_put') else 'BEGIN')
        try:
            result = self._request(req, op, vault, now)
            self.db.execute('COMMIT')
            return result
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def _request(self, req, op, vault, now):
        row = self.db.execute('SELECT revision FROM heads WHERE vault=?', (vault,)).fetchone()
        head = row[0] if row else 0
        if op == 'head':
            return {'revision': head}
        if op == 'history':
            rows = self.db.execute('SELECT revision,created FROM revisions WHERE vault=? ORDER BY revision DESC LIMIT ?', (vault, HISTORY)).fetchall()
            return {'revision': head, 'history': [{'revision': n, 'created': t} for n, t in rows]}
        if op == 'read':
            revision = integer(req['revision'])
            if revision == 0:
                revision = head
            row = self.db.execute('SELECT manifest FROM revisions WHERE vault=? AND revision=?', (vault, revision)).fetchone()
            if row is None:
                raise SyncError('not_found')
            refs = [r[0] for r in self.db.execute('SELECT digest FROM refs WHERE vault=? AND revision=? ORDER BY digest', (vault, revision))]
            return {'revision': revision, 'head': head, 'manifest': encode(row[0]), 'blobs': refs}
        if op == 'blob_get':
            name = digest(req['digest'])
            row = self.db.execute('SELECT data FROM blobs WHERE vault=? AND digest=?', (vault, name)).fetchone()
            if row is None:
                raise SyncError('not_found')
            return {'digest': name, 'data': encode(row[0])}
        if op == 'blob_put':
            name = digest(req['digest'])
            data = decode(req['data'], CHUNK_LIMIT, minimum=29)
            if hashlib.sha256(data).hexdigest() != name:
                raise SyncError('digest_mismatch')
            self.collect(now)
            exists = self.db.execute('SELECT 1 FROM blobs WHERE vault=? AND digest=?', (vault, name)).fetchone()
            if not exists:
                count = self.db.execute('SELECT count(*) FROM blobs').fetchone()[0]
                if count >= MAX_BLOBS or self.used() + len(data) > self.quota:
                    raise SyncError('quota_exceeded')
                self.db.execute('INSERT INTO blobs VALUES(?,?,?,?)', (vault, name, data, now))
            else:
                self.db.execute('UPDATE blobs SET touched=? WHERE vault=? AND digest=?', (now, vault, name))
            return {'digest': name}
        expected = integer(req['expected'])
        if expected != head:
            raise SyncError('conflict')
        self.collect(now)
        manifest = decode(req['manifest'], MANIFEST_LIMIT)
        names = req['blobs']
        if not isinstance(names, list) or not 1 <= len(names) <= 128 or any(not isinstance(n, str) for n in names) or len(set(names)) != len(names):
            raise SyncError('invalid_blobs')
        total = 0
        for name in names:
            digest(name)
            row = self.db.execute('SELECT length(data) FROM blobs WHERE vault=? AND digest=?', (vault, name)).fetchone()
            if not row:
                raise SyncError('missing_blob')
            total += row[0]
        if total > VAULT_LIMIT + 128 * 64:
            raise SyncError('invalid_size')
        if head == 0 and self.db.execute('SELECT count(*) FROM heads').fetchone()[0] >= 32:
            raise SyncError('quota_exceeded')
        if self.used() + len(manifest) > self.quota:
            raise SyncError('quota_exceeded')
        revision = head + 1
        self.db.execute('INSERT INTO revisions VALUES(?,?,?,?)', (vault, revision, manifest, now))
        self.db.executemany('INSERT INTO refs VALUES(?,?,?)', [(vault, revision, name) for name in names])
        self.db.execute('INSERT INTO heads VALUES(?,?) ON CONFLICT(vault) DO UPDATE SET revision=excluded.revision', (vault, revision))
        self.db.execute('DELETE FROM revisions WHERE vault=? AND revision<=?', (vault, revision - HISTORY))
        return {'revision': revision}


def read_request(stream, timeout=45):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while len(data) <= REQUEST_LIMIT:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([stream], [], [], left)[0]:
            raise SyncError('request_timeout')
        chunk = os.read(stream.fileno(), min(65536, REQUEST_LIMIT + 1 - len(data)))
        if not chunk:
            break
        data.extend(chunk)
        if b'\n' in chunk:
            break
    if len(data) > REQUEST_LIMIT:
        raise SyncError('invalid_size')
    try:
        return json.loads(data)
    except (ValueError, UnicodeError):
        raise SyncError('invalid_json') from None


def main():
    os.umask(0o077)
    # Forced command: ignore SSH_ORIGINAL_COMMAND and all client arguments.
    if len(sys.argv) != 1:
        return 2
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
        resource.setrlimit(resource.RLIMIT_AS, (256 * 1024**2, 256 * 1024**2))
        req = read_request(sys.stdin.buffer)
        store = Store('/var/lib/ssh-hub-sync/data')
        try:
            response = {'ok': True, 'protocol': PROTOCOL, 'result': store.request(req)}
        finally:
            store.close()
    except SyncError as error:
        response = {'ok': False, 'protocol': PROTOCOL, 'error': error.code}
    except (sqlite3.Error, OSError, MemoryError):
        response = {'ok': False, 'protocol': PROTOCOL, 'error': 'storage_unavailable'}
    sys.stdout.write(json.dumps(response, separators=(',', ':')) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
