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
        self.db.execute('PRAGMA foreign_keys=ON')
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
            CREATE TABLE IF NOT EXISTS devices(
                id TEXT PRIMARY KEY, user_id TEXT NOT NULL, client_id TEXT NOT NULL,
                name TEXT NOT NULL, kind TEXT NOT NULL, platform TEXT NOT NULL,
                version TEXT NOT NULL, created INTEGER NOT NULL, last_seen INTEGER NOT NULL,
                ip TEXT NOT NULL, last_sync INTEGER NOT NULL DEFAULT 0,
                UNIQUE(user_id,client_id));
            CREATE TABLE IF NOT EXISTS session_details(
                digest TEXT PRIMARY KEY REFERENCES sessions(digest) ON DELETE CASCADE,
                id TEXT UNIQUE NOT NULL, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER NOT NULL,
                actor TEXT NOT NULL, target TEXT NOT NULL, action TEXT NOT NULL,
                device TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS events_actor ON events(actor,created);
            CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id,last_seen);
            CREATE TABLE IF NOT EXISTS daily(
                day TEXT NOT NULL, user_id TEXT NOT NULL, requests INTEGER NOT NULL DEFAULT 0,
                uploaded INTEGER NOT NULL DEFAULT 0, downloaded INTEGER NOT NULL DEFAULT 0,
                pushes INTEGER NOT NULL DEFAULT 0, pulls INTEGER NOT NULL DEFAULT 0,
                errors INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day,user_id));
        ''')
        # Additive migration: keep the original users/sessions tables and tokens intact.
        rows = self.db.execute('SELECT s.digest,s.user_id,s.device,s.created FROM sessions s LEFT JOIN session_details d ON d.digest=s.digest WHERE d.digest IS NULL').fetchall()
        with self.db:
            for digest, user, name, created in rows:
                device_id = str(uuid.uuid4())
                self.db.execute('INSERT INTO devices(id,user_id,client_id,name,kind,platform,version,created,last_seen,ip) VALUES(?,?,?,?,?,?,?,?,?,?)',
                                (device_id, user, device_id, self.text(name, 80, 'SSH Hub'), 'web' if name == 'Web administration' else 'app', '', '', created, created, ''))
                self.db.execute('INSERT INTO session_details VALUES(?,?,?)', (digest, str(uuid.uuid4()), device_id))
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

    def create(self, username, password, role='user', actor='console'):
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
                self._event(actor, identifier, 'user_created')
        except sqlite3.IntegrityError:
            raise AuthError('username_exists') from None
        return {'id': identifier, 'username': name, 'role': role, 'vault': vault}

    @staticmethod
    def digest(token):
        return hashlib.sha256(token.encode()).hexdigest()

    @staticmethod
    def text(value, limit, fallback=''):
        return re.sub(r'[\x00-\x1f\x7f]', '', value).strip()[:limit] or fallback if isinstance(value, str) else fallback

    def login(self, username, password, device='SSH Hub', *, client_id=None, kind='app', platform='', version='', ip=''):
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
        if client_id is not None:
            try:
                if not isinstance(client_id, str) or str(uuid.UUID(client_id)) != client_id: raise ValueError()
            except (ValueError, AttributeError):
                raise AuthError('invalid_device') from None
        client_id = client_id or str(uuid.uuid4())
        device = self.text(device, 80, 'SSH Hub')
        with self.db:
            self.db.execute('DELETE FROM failures WHERE name=?', (name,))
            self.db.execute('DELETE FROM sessions WHERE expires<?', (now,))
            # Keep at most 20 device sessions per account.
            self.db.execute('DELETE FROM sessions WHERE digest IN (SELECT digest FROM sessions WHERE user_id=? ORDER BY created DESC LIMIT -1 OFFSET 19)', (row[0],))
            found = self.db.execute('SELECT id FROM devices WHERE user_id=? AND client_id=?', (row[0], client_id)).fetchone()
            device_id = found[0] if found else str(uuid.uuid4())
            if not found:
                # Retain up to 100 known devices per user, pruning only disconnected metadata.
                if self.db.execute('SELECT count(*) FROM devices WHERE user_id=?', (row[0],)).fetchone()[0] >= 100:
                    self.db.execute('DELETE FROM devices WHERE id=(SELECT d.id FROM devices d WHERE d.user_id=? AND NOT EXISTS (SELECT 1 FROM session_details sd JOIN sessions s ON sd.digest=s.digest WHERE sd.device_id=d.id AND s.expires>?) ORDER BY d.last_seen LIMIT 1)', (row[0], now))
                self.db.execute('INSERT INTO devices(id,user_id,client_id,name,kind,platform,version,created,last_seen,ip) VALUES(?,?,?,?,?,?,?,?,?,?)',
                                (device_id, row[0], client_id, device, 'web' if kind == 'web' else 'app', self.text(platform, 40), self.text(version, 40), now, now, self.text(ip, 64)))
            else:
                self.db.execute('UPDATE devices SET last_seen=?,ip=?,platform=?,version=? WHERE id=?', (now, self.text(ip, 64), self.text(platform, 40), self.text(version, 40), device_id))
            self.db.execute('INSERT INTO sessions VALUES(?,?,?,?,?)', (self.digest(token), row[0], now+30*86400, now, device))
            self.db.execute('INSERT INTO session_details VALUES(?,?,?)', (self.digest(token), str(uuid.uuid4()), device_id))
            self._event(row[0], row[0], 'login', device_id)
        return {'token': token, 'expiresAt': now+30*86400, 'username': name, 'role': row[3], 'vault': row[5], 'protocol': 1}

    def authenticate(self, token, ip=''):
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{40,100}', token):
            raise AuthError('unauthorized')
        row = self.db.execute('SELECT u.id,u.username,u.role,u.vault FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.digest=? AND s.expires>? AND u.enabled=1', (self.digest(token), int(time.time()))).fetchone()
        if not row:
            raise AuthError('unauthorized')
        now = int(time.time())
        with self.db:
            self.db.execute('UPDATE devices SET last_seen=?,ip=CASE WHEN ?<>\'\' THEN ? ELSE ip END WHERE id=(SELECT device_id FROM session_details WHERE digest=?) AND (last_seen<? OR ip=\'\')', (now, ip, ip, self.digest(token), now-60))
        return dict(zip(['id', 'username', 'role', 'vault'], row))

    def logout(self, token):
        with self.db:
            row = self.db.execute('SELECT s.user_id,d.device_id FROM sessions s JOIN session_details d ON d.digest=s.digest WHERE s.digest=?', (self.digest(token),)).fetchone()
            if row: self._event(row[0], row[0], 'logout', row[1])
            self.db.execute('DELETE FROM sessions WHERE digest=?', (self.digest(token),))

    def list(self):
        rows = self.db.execute('SELECT id,username,role,enabled,created FROM users ORDER BY username').fetchall()
        return [dict(zip(['id', 'username', 'role', 'enabled', 'created'], row)) for row in rows]

    def enable(self, identifier, enabled, actor):
        if identifier == actor or type(enabled) is not bool:
            raise AuthError('invalid_update')
        with self.db:
            self.db.execute('UPDATE users SET enabled=enabled WHERE id=?', (identifier,))
            row = self.db.execute('SELECT role,enabled FROM users WHERE id=?', (identifier,)).fetchone()
            if not row:
                raise AuthError('invalid_update')
            if row[0] == 'admin' and row[1] and not enabled: self._keep_admin()
            self.db.execute('UPDATE users SET enabled=? WHERE id=?', (int(enabled), identifier))
            if not enabled:
                self.db.execute('DELETE FROM sessions WHERE user_id=?', (identifier,))
            self._event(actor, identifier, 'user_enabled' if enabled else 'user_disabled')

    def reset_password(self, username, password, actor='console', expected_hash=None):
        name = self.username(username); salt = secrets.token_bytes(16); hashed = self.password_hash(password, salt)
        with self.db:
            self.db.execute('UPDATE users SET enabled=enabled WHERE username=?', (name,))
            row = self.db.execute('SELECT id,password FROM users WHERE username=?', (name,)).fetchone()
            if not row:
                raise AuthError('unknown_user')
            if expected_hash is not None and not hmac.compare_digest(expected_hash, row[1]): raise AuthError('invalid_credentials')
            self.db.execute('UPDATE users SET salt=?,password=? WHERE id=?', (salt, hashed, row[0]))
            self.db.execute('DELETE FROM sessions WHERE user_id=?', (row[0],))
            self._event(actor, row[0], 'password_changed' if actor == row[0] else 'password_reset')

    def change_password(self, user, current, password):
        row = self.db.execute('SELECT salt,password FROM users WHERE id=?', (user['id'],)).fetchone()
        try: valid = row and hmac.compare_digest(self.password_hash(current, row[0]), row[1])
        except AuthError: valid = False
        if not valid: raise AuthError('invalid_credentials')
        self.reset_password(user['username'], password, actor=user['id'], expected_hash=row[1])

    def _keep_admin(self):
        if self.db.execute("SELECT count(*) FROM users WHERE role='admin' AND enabled=1").fetchone()[0] <= 1:
            raise AuthError('last_admin')

    def set_role(self, identifier, role, actor):
        if role not in ('user', 'admin') or identifier == actor: raise AuthError('invalid_update')
        with self.db:
            # Serialize the last-administrator check with the update.
            self.db.execute('UPDATE users SET enabled=enabled WHERE id=?', (identifier,))
            row = self.db.execute('SELECT role,enabled FROM users WHERE id=?', (identifier,)).fetchone()
            if not row: raise AuthError('unknown_user')
            if row[0] == role: return
            if row[0] == 'admin' and row[1]: self._keep_admin()
            self.db.execute('UPDATE users SET role=? WHERE id=?', (role, identifier))
            self.db.execute('DELETE FROM sessions WHERE user_id=?', (identifier,))
            self._event(actor, identifier, 'role_admin' if role == 'admin' else 'role_user')

    def revoke_user(self, identifier, actor):
        with self.db:
            if not self.db.execute('SELECT 1 FROM users WHERE id=?', (identifier,)).fetchone(): raise AuthError('unknown_user')
            self.db.execute('DELETE FROM sessions WHERE user_id=?', (identifier,))
            self._event(actor, identifier, 'sessions_revoked')

    def device_action(self, identifier, actor, *, admin=False, name=None):
        with self.db:
            row = self.db.execute('SELECT user_id FROM devices WHERE id=?', (identifier,)).fetchone()
            if not row or (row[0] != actor and not admin): raise AuthError('device_not_found')
            if name is not None:
                name = self.text(name, 80)
                if not name: raise AuthError('invalid_device')
                self.db.execute('UPDATE devices SET name=? WHERE id=?', (name, identifier))
                action = 'device_renamed'
            else:
                self.db.execute('DELETE FROM sessions WHERE digest IN (SELECT digest FROM session_details WHERE device_id=?)', (identifier,))
                action = 'device_revoked'
            self._event(actor, row[0], action, identifier)

    def _event(self, actor, target, action, device='', revision=0):
        self.db.execute('INSERT INTO events(created,actor,target,action,device,revision) VALUES(?,?,?,?,?,?)', (int(time.time()), actor, target, action, device, revision))
        self.db.execute('DELETE FROM events WHERE id <= (SELECT COALESCE(MAX(id),0)-20000 FROM events) OR created<?', (int(time.time())-90*86400,))

    def record_sync(self, user, token, op, success, uploaded, downloaded, revision=0):
        now = int(time.time()); day = time.strftime('%Y-%m-%d', time.gmtime(now))
        with self.db:
            self.db.execute('''INSERT INTO daily(day,user_id,requests,uploaded,downloaded,pushes,pulls,errors) VALUES(?,?,1,?,?,?,?,?)
                ON CONFLICT(day,user_id) DO UPDATE SET requests=requests+1,uploaded=uploaded+excluded.uploaded,downloaded=downloaded+excluded.downloaded,
                pushes=pushes+excluded.pushes,pulls=pulls+excluded.pulls,errors=errors+excluded.errors''',
                (day, user, uploaded, downloaded, int(success and op == 'commit'), int(success and op == 'read'), int(not success)))
            self.db.execute('DELETE FROM daily WHERE day<?', (time.strftime('%Y-%m-%d', time.gmtime(now-90*86400)),))
            if op in ('commit', 'read') or not success:
                row = self.db.execute('SELECT device_id FROM session_details WHERE digest=?', (self.digest(token),)).fetchone()
                device = row[0] if row else ''
                self._event(user, user, 'sync_push' if success and op == 'commit' else 'sync_pull' if success else 'sync_error', device, revision if type(revision) is int else 0)
                if success: self.db.execute('UPDATE devices SET last_sync=? WHERE id=?', (now, device))

    def devices(self, user=None, token=''):
        now = int(time.time())
        rows = self.db.execute('''SELECT d.id,d.user_id,u.username,d.name,d.kind,d.platform,d.version,d.created,d.last_seen,d.ip,d.last_sync,
            (SELECT count(*) FROM session_details sd JOIN sessions s ON s.digest=sd.digest WHERE sd.device_id=d.id AND s.expires>?),
            EXISTS(SELECT 1 FROM session_details sd WHERE sd.device_id=d.id AND sd.digest=?)
            FROM devices d JOIN users u ON u.id=d.user_id WHERE (? IS NULL OR d.user_id=?) ORDER BY d.last_seen DESC LIMIT 10000''', (now, self.digest(token), user, user)).fetchall()
        keys = ['id','userId','username','name','kind','platform','version','created','lastSeen','ip','lastSync','sessions','current']
        return [dict(zip(keys, row)) for row in rows]

    def activity(self, user=None, limit=100):
        rows = self.db.execute('''SELECT e.id,e.created,e.action,e.revision,COALESCE(a.username,'Консоль'),COALESCE(t.username,''),COALESCE(d.name,'')
            FROM events e LEFT JOIN users a ON a.id=e.actor LEFT JOIN users t ON t.id=e.target LEFT JOIN devices d ON d.id=e.device
            WHERE (? IS NULL OR e.target=?) ORDER BY e.id DESC LIMIT ?''', (user, user, min(limit, 200))).fetchall()
        return [dict(zip(['id','created','action','revision','actor','username','device'], row)) for row in rows]

    def statistics(self, user=None):
        since = time.strftime('%Y-%m-%d', time.gmtime(time.time()-29*86400))
        rows = self.db.execute('SELECT day,SUM(requests),SUM(uploaded),SUM(downloaded),SUM(pushes),SUM(pulls),SUM(errors) FROM daily WHERE day>=? AND (? IS NULL OR user_id=?) GROUP BY day ORDER BY day', (since, user, user)).fetchall()
        return [dict(zip(['day','requests','uploaded','downloaded','pushes','pulls','errors'], row)) for row in rows]
