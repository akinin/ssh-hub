#!/usr/bin/env python3
"""Online SQLite backup, one previous copy; ciphertext only. Run by systemd."""
import fcntl
import os
from pathlib import Path
import shutil
import sqlite3
import uuid


def backup(source, destination):
    source, destination = Path(source), Path(destination)
    if source.is_symlink() or not source.is_file() or destination.is_symlink() or not destination.is_dir():
        raise ValueError('Unsafe backup path')
    with (destination / '.backup.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if shutil.disk_usage(destination).free < source.stat().st_size + 512 * 1024**2:
            raise ValueError('Not enough space for an atomic backup')
        temporary = destination / ('.new-' + str(uuid.uuid4()) + '.sqlite3')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        try:
            reader = sqlite3.connect('file:' + source.as_posix() + '?mode=ro', uri=True, timeout=10)
            writer = sqlite3.connect(temporary)
            try:
                reader.backup(writer, pages=256, sleep=0.05)
                if writer.execute('PRAGMA quick_check').fetchone() != ('ok',):
                    raise ValueError('Backup integrity check failed')
            finally:
                writer.close(); reader.close()
            with temporary.open('rb') as file:
                os.fsync(file.fileno())
            os.replace(temporary, destination / 'latest.sqlite3')
            fd = os.open(destination, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    os.umask(0o077)
    root = Path('/var/lib/ssh-hub-sync')
    destination = Path('/var/backups/ssh-hub-sync')
    if (root/'data/sync.sqlite3').is_file():
        backup(root/'data/sync.sqlite3', destination)
    if (root/'cloud/accounts.sqlite3').is_file():
        target = destination/'cloud/accounts'; target.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup(root/'cloud/accounts.sqlite3', target)
        for database in (root/'cloud/users').glob('*/sync.sqlite3'):
            if str(uuid.UUID(database.parent.name)) != database.parent.name or database.parent.is_symlink():
                raise ValueError('Invalid account storage')
            target = destination/'cloud/users'/database.parent.name; target.mkdir(parents=True, exist_ok=True, mode=0o700)
            backup(database, target)
