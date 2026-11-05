#!/usr/bin/env python3
"""Run as root through the Proxmox console. Passwords are hidden TTY input."""
import argparse
import getpass
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))

from accounts import Accounts


def main():
    parser = argparse.ArgumentParser(description='SSH Hub Sync account administration (no public registration)')
    parser.add_argument('operation', choices=['create-admin', 'create-user', 'reset-password', 'list'])
    parser.add_argument('username', nargs='?')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run through the administrator console')
    os.umask(0o077)
    accounts = Accounts('/var/lib/ssh-hub-sync/cloud')
    try:
        if args.operation == 'list':
            for user in accounts.list():
                print(user['username'], user['role'], 'enabled' if user['enabled'] else 'disabled')
            return
        if not args.username:
            raise SystemExit('Username is required')
        password = getpass.getpass('Account password (12+ characters): ')
        if password != getpass.getpass('Repeat password: '):
            raise SystemExit('Passwords differ')
        if args.operation == 'reset-password':
            accounts.reset_password(args.username, password)
        else:
            accounts.create(args.username, password, 'admin' if args.operation == 'create-admin' else 'user')
        print('Account saved; password was not printed. Data encryption password is separate.')
    finally:
        accounts.close()
        # Account database stays writable by the confined service, not world-readable.
        import pwd
        owner = pwd.getpwnam('ssh-hub-sync')
        os.chown('/var/lib/ssh-hub-sync/cloud', owner.pw_uid, owner.pw_gid)
        os.chown('/var/lib/ssh-hub-sync/cloud/accounts.sqlite3', owner.pw_uid, owner.pw_gid)


if __name__ == '__main__':
    main()
