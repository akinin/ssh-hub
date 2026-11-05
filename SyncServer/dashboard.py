"""Read-only administrative metadata. Never read or decrypt snapshot contents."""
import shutil
import sqlite3
import time
import uuid


def storage(root, user):
    if str(uuid.UUID(user['id'])) != user['id']: raise ValueError('Invalid account storage')
    directory = root/'users'/user['id']
    path = directory/'sync.sqlite3'
    empty = {'bytes': 0, 'fileBytes': 0, 'revision': 0, 'versions': 0, 'lastSync': 0, 'history': []}
    if not path.exists(): return empty
    if root.is_symlink() or (root/'users').is_symlink() or directory.is_symlink() or path.is_symlink():
        raise ValueError('Unsafe account storage')
    db = sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True, timeout=5)
    try:
        db.execute('PRAGMA query_only=ON'); db.execute('BEGIN')
        used = db.execute('SELECT COALESCE(SUM(length(data)),0) FROM blobs').fetchone()[0]
        used += db.execute('SELECT COALESCE(SUM(length(manifest)),0) FROM revisions').fetchone()[0]
        row = db.execute('SELECT revision FROM heads WHERE vault=?', (user['vault'],)).fetchone()
        history = db.execute('''SELECT r.revision,r.created,length(r.manifest)+COALESCE((SELECT SUM(length(b.data))
            FROM refs f JOIN blobs b ON b.vault=f.vault AND b.digest=f.digest WHERE f.vault=r.vault AND f.revision=r.revision),0)
            FROM revisions r WHERE r.vault=? ORDER BY r.revision DESC LIMIT 20''', (user['vault'],)).fetchall()
        return {'bytes': used, 'fileBytes': path.stat().st_size, 'revision': row[0] if row else 0,
                'versions': len(history), 'lastSync': history[0][1] if history else 0,
                'history': [dict(zip(['revision','created','bytes'], item)) for item in history]}
    finally:
        db.close()


def dashboard(accounts, user, token, *, admin=False, quota, total_quota, started, backup_root=None):
    scope = None if admin else user['id']
    users = accounts.db.execute('SELECT id,username,role,enabled,created,vault FROM users WHERE (? IS NULL OR id=?) ORDER BY username', (scope, scope)).fetchall()
    devices = accounts.devices(scope, token)
    by_user = {}
    for device in devices: by_user.setdefault(device['userId'], []).append(device)
    result = []
    for row in users:
        item = dict(zip(['id','username','role','enabled','created','vault'], row))
        own = by_user.get(item['id'], [])
        item.update(storage(accounts.root, item))
        item.update(devices=len(own), activeDevices=sum(d['sessions'] > 0 for d in own), sessions=sum(d['sessions'] for d in own),
                    lastSeen=max((d['lastSeen'] for d in own), default=0), quotaBytes=quota)
        result.append(item)
    daily = accounts.statistics(scope)
    summary = {'users': len(result), 'enabledUsers': sum(bool(u['enabled']) for u in result),
               'admins': sum(u['role'] == 'admin' and bool(u['enabled']) for u in result),
               'devices': len(devices), 'activeDevices': sum(d['sessions'] > 0 for d in devices),
               'recentDevices': sum(d['sessions'] > 0 and d['lastSeen'] >= time.time()-300 for d in devices),
               'sessions': sum(d['sessions'] for d in devices), 'bytes': sum(u['bytes'] for u in result),
               'fileBytes': sum(u['fileBytes'] for u in result), 'versions': sum(u['versions'] for u in result),
               'lastSync': max((u['lastSync'] for u in result), default=0), 'quotaBytes': total_quota if admin else quota}
    for field in ['requests','uploaded','downloaded','pushes','pulls','errors']:
        summary[field] = sum(d[field] for d in daily)
    response = {'summary': summary, 'users': result, 'devices': devices, 'daily': daily,
                'activity': accounts.activity(scope), 'generatedAt': int(time.time()), 'periodDays': 30,
                'historyLimit': 20, 'registration': False, 'version': '2.0', 'scope': 'admin' if admin else 'account'}
    if not admin:
        response['history'] = result[0]['history']
    else:
        for item in result: item.pop('history')
        disk = shutil.disk_usage(accounts.root)
        backup = backup_root/'cloud/accounts/latest.sqlite3' if backup_root else None
        response['server'] = {'uptimeSeconds': max(0, int(time.time()-started)), 'diskTotalBytes': disk.total,
                              'diskFreeBytes': disk.free, 'lastBackup': int(backup.stat().st_mtime) if backup and backup.is_file() and not backup.is_symlink() else None}
    return response
