#!/usr/bin/env python3
"""Explicit opt-in integration test against a dedicated test deployment.

Creates one synthetic vault and writes its ID to a private ledger so an
administrator can remove that vault only. Never opens app/Keychain data.
"""
import argparse
import json
import os
from pathlib import Path
import uuid

from client import Remote
from cryptography.exceptions import InvalidTag


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--known-hosts', required=True)
    parser.add_argument('--identity')
    parser.add_argument('--ledger', type=Path, required=True)
    parser.add_argument('--allow-test-writes', action='store_true', required=True)
    args = parser.parse_args()
    vault = str(uuid.uuid4())
    fd = os.open(args.ledger, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump({'ownedTestVault': vault}, file)
    remote = Remote(args.host, args.known_hosts, args.identity)
    password = 'owned-fixture-vault-passphrase'
    plain = json.dumps({'records': [{'name': 'fixture-node', 'password': 'owned-fixture-password', 'totp': 'JBSWY3DPEHPK3PXP'}]}).encode() + b' ' * (4 * 1024 * 1024)
    assert remote.request('head', vault=vault)['revision'] == 0
    assert remote.push(plain, password, vault, 0)['revision'] == 1
    assert remote.pull(password, vault) == (1, plain)
    try:
        remote.push(b'owned-conflicting-fixture', password, vault, 0)
    except ValueError as error:
        assert str(error) == 'conflict'
    else:
        raise AssertionError('Stale write accepted')
    assert remote.push(b'owned-second-revision', password, vault, 1)['revision'] == 2
    assert remote.pull(password, vault, 1) == (1, plain)
    try:
        remote.pull('wrong-test-passphrase', vault)
    except InvalidTag:
        pass
    else:
        raise AssertionError('Wrong password accepted')
    try:
        remote.pull(password, vault, last_seen=3)
    except ValueError as error:
        assert 'rollback' in str(error)
    else:
        raise AssertionError('Rollback accepted')
    assert len(remote.request('history', vault=vault)['history']) == 2
    print('Remote E2EE, multi-chunk transfer, stale-write conflict, history, rollback and wrong-password rejection passed. Synthetic data only.')


if __name__ == '__main__':
    main()
