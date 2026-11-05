"""Admin-provisioned accounts and revocable opaque sessions; no signup path."""
import hashlib
import hmac
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
import uuid


class AuthError(Exception):
    pass


class Accounts:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = self.root/'accounts.sqlite3'
        if self.root.is_symlink() or path.is_symlink():
            raise AuthError('storage_unavailable')
        self.db = sqlite3.connect(path, timeout=10)
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS users(
                id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
                salt BLOB NOT NULL, password BLOB NOT NULL,
                role TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
                vault TEXT UNIQUE NOT NULL, created INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions(
                digest TEXT PRIMARY KEY, user_id TEXT NOT NULL,
                expires INTEGER NOT NULL, created INTEGER NOT NULL,
                device TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS failures(
                name TEXT PRIMARY KEY, count INTEGER NOT NULL, until INTEGER NOT NULL);
        ''')
        os.chmod(path, 0o600)

    def close(self):
        self.db.close()

    @staticmethod
    def username(value):
        if not isinstance(value, str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{2,63}', value):
            raise AuthError('invalid_username')
        return value.lower()

    @staticmethod
    def password_hash(value, salt):
        if not isinstance(value, str) or not 12 <= len(value) <= 1024 or len(value.encode()) > 4096:
            raise AuthError('invalid_password')
        return hashlib.scrypt(value.encode(), salt=salt, n=131072, r=8, p=1, maxmem=256*1024**2, dklen=32)

    def create(self, username, password, role='user'):
        name = self.username(username)
        if role not in ('user', 'admin'):
            raise AuthError('invalid_role')
        salt = secrets.token_bytes(16)
        hashed = self.password_hash(password, salt)
        identifier, vault, now = str(uuid.uuid4()), str(uuid.uuid4()), int(time.time())
        try:
            with self.db:
                if self.db.execute('SELECT count(*) FROM users').fetchone()[0] >= 100:
                    raise AuthError('user_limit')
                self.db.execute('INSERT INTO users VALUES(?,?,?,?,?,1,?,?)', (identifier, name, salt, hashed, role, vault, now))
        except sqlite3.IntegrityError:
            raise AuthError('username_exists') from None
        return {'id': identifier, 'username': name, 'role': role, 'vault': vault}

    @staticmethod
    def digest(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def login(self, username, password, device='SSH Hub'):
        name = self.username(username)
        now = int(time.time())
        attempt = self.db.execute('SELECT count,until FROM failures WHERE name=?', (name,)).fetchone()
        if attempt and attempt[0] >= 5 and attempt[1] > now:
            raise AuthError('try_later')
        row = self.db.execute('SELECT id,salt,password,role,enabled,vault FROM users WHERE username=?', (name,)).fetchone()
        try:
            hashed = self.password_hash(password, row[1] if row else bytes(16))
        except AuthError:
            hashed = bytes(32)
        if not row or not row[4] or not hmac.compare_digest(hashed, row[2]):
            with self.db:
                # Bound unknown names; no public username enumeration.
                self.db.execute('DELETE FROM failures WHERE until<?', (now,))
                if self.db.execute('SELECT count(*) FROM failures').fetchone()[0] < 1024:
                    count = (attempt[0] if attempt and attempt[1] > now else 0) + 1
                    self.db.execute('INSERT INTO failures VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET count=excluded.count,until=excluded.until', (name, count, now+300))
            raise AuthError('invalid_credentials')
        token = secrets.token_urlsafe(32)
        with self.db:
            self.db.execute('DELETE FROM failures WHERE name=?', (name,))
            self.db.execute('DELETE FROM sessions WHERE expires<?', (now,))
            # Keep at most 20 device sessions per account.
            self.db.execute('DELETE FROM sessions WHERE digest IN (SELECT digest FROM sessions WHERE user_id=? ORDER BY created DESC LIMIT -1 OFFSET 19)', (row[0],))
            self.db.execute('INSERT INTO sessions VALUES(?,?,?,?,?)', (self.digest(token), row[0], now+30*86400, now, str(device)[:80]))
        return {'token': token, 'expiresAt': now+30*86400, 'username': name, 'role': row[3], 'vault': row[5], 'protocol': 1}

    def authenticate(self, token):
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{40,100}', token):
            raise AuthError('unauthorized')
        row = self.db.execute('SELECT u.id,u.username,u.role,u.vault FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.digest=? AND s.expires>? AND u.enabled=1', (self.digest(token), int(time.time()))).fetchone()
        if not row:
            raise AuthError('unauthorized')
        return dict(zip(['id', 'username', 'role', 'vault'], row))

    def logout(self, token):
        with self.db:
            self.db.execute('DELETE FROM sessions WHERE digest=?', (self.digest(token),))

    def list(self):
        rows = self.db.execute('SELECT id,username,role,enabled,created FROM users ORDER BY username').fetchall()
        return [dict(zip(['id', 'username', 'role', 'enabled', 'created'], row)) for row in rows]

    def enable(self, identifier, enabled, actor):
        if identifier == actor or type(enabled) is not bool:
            raise AuthError('invalid_update')
        with self.db:
            row = self.db.execute('SELECT role FROM users WHERE id=?', (identifier,)).fetchone()
            if not row or row[0] == 'admin':
                raise AuthError('invalid_update')
            self.db.execute('UPDATE users SET enabled=? WHERE id=?', (int(enabled), identifier))
            if not enabled:
                self.db.execute('DELETE FROM sessions WHERE user_id=?', (identifier,))

    def reset_password(self, username, password):
        name = self.username(username); salt = secrets.token_bytes(16); hashed = self.password_hash(password, salt)
        with self.db:
            row = self.db.execute('SELECT id FROM users WHERE username=?', (name,)).fetchone()
            if not row:
                raise AuthError('unknown_user')
            self.db.execute('UPDATE users SET salt=?,password=? WHERE id=?', (salt, hashed, row[0]))
            self.db.execute('DELETE FROM sessions WHERE user_id=?', (row[0],))
