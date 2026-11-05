#!/usr/bin/env python3
"""Explicit reference client; no application/Keychain data is read automatically."""
import argparse
import base64
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading

from crypto import seal, unseal, MAXIMUM


class Remote:
    def __init__(self, host, known_hosts=None, identity=None, port=22):
        if not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:%_-]{0,252}', host) or not 1 <= port <= 65535:
            raise ValueError('Invalid SSH endpoint')
        self.command = ['/usr/bin/ssh' if os.name != 'nt' else 'ssh.exe', '-T',
                        '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                        '-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1',
                        '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                        '-o', 'ClearAllForwardings=yes', '-o', 'ForwardAgent=no',
                        '-o', 'PermitLocalCommand=no', '-o', 'RemoteCommand=none',
                        '-o', 'RequestTTY=no', '-p', str(port), '-l', 'ssh-hub-sync']
        if known_hosts:
            self.command += ['-o', 'UserKnownHostsFile=' + str(Path(known_hosts).resolve())]
        if identity:
            self.command += ['-o', 'IdentitiesOnly=yes', '-i', str(Path(identity).resolve())]
        self.command += [host, 'ssh-hub-sync-rpc']

    def request(self, op, **values):
        request = json.dumps({'protocol': 1, 'op': op, **values}, separators=(',', ':')).encode() + b'\n'
        if len(request) > 6 * 1024 * 1024:
            raise ValueError('Request too large')
        process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        outputs = [bytearray(), bytearray()]
        overflow = threading.Event()
        def drain(stream, index, limit):
            while True:
                chunk = stream.read(65536)
                if not chunk:
                    return
                outputs[index].extend(chunk)
                if len(outputs[index]) > limit:
                    overflow.set(); process.kill(); return
        def send():
            try:
                process.stdin.write(request)
                process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        readers = [threading.Thread(target=drain, args=(process.stdout, 0, 6 * 1024 * 1024), daemon=True),
                   threading.Thread(target=drain, args=(process.stderr, 1, 65536), daemon=True),
                   threading.Thread(target=send, daemon=True)]
        for thread in readers:
            thread.start()
        try:
            process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
            raise ValueError('SSH request timed out') from None
        finally:
            for thread in readers:
                thread.join(timeout=5)
            for stream in [process.stdin, process.stdout, process.stderr]:
                try:
                    stream.close()
                except OSError:
                    pass
        if overflow.is_set():
            raise ValueError('SSH response exceeds limit')
        if process.returncode != 0:
            # Never log raw remote stderr or request payloads.
            raise ValueError('SSH authentication or transport failed (exit %d)' % process.returncode)
        response = json.loads(outputs[0])
        if response.get('protocol') != 1 or type(response.get('ok')) is not bool:
            raise ValueError('Invalid server response')
        if not response['ok']:
            code = response.get('error', '')
            allowed = {'conflict', 'not_found', 'quota_exceeded', 'missing_blob', 'storage_unavailable', 'invalid_size', 'invalid_request', 'request_timeout'}
            raise ValueError(code if code in allowed else 'Server rejected request')
        return response['result']

    def push(self, data, password, vault, expected):
        # Caller supplies its last acknowledged revision, not a fresh head
        # fetched immediately before an unconditional overwrite.
        manifest, chunks = seal(data, password, vault, expected)
        for name, chunk in chunks:
            self.request('blob_put', vault=vault, digest=name, data=base64.b64encode(chunk).decode())
        return self.request('commit', vault=vault, expected=expected, manifest=base64.b64encode(manifest).decode(), blobs=[name for name, _ in chunks])

    def pull(self, password, vault, revision=0, last_seen=0):
        response = self.request('read', vault=vault, revision=revision)
        manifest = base64.b64decode(response['manifest'], validate=True)
        # Authenticate the manifest before downloading blobs named by it.
        from crypto import open_manifest
        metadata, _ = open_manifest(manifest, password, vault)
        if metadata['revision'] != response['revision'] or (revision and revision != response['revision']) or (not revision and response['revision'] < last_seen):
            raise ValueError('Snapshot revision mismatch or rollback')
        if set(metadata['chunks']) != set(response['blobs']):
            raise ValueError('Server manifest references differ')
        chunks = {}
        for name in metadata['chunks']:
            data = self.request('blob_get', vault=vault, digest=name)
            chunk = base64.b64decode(data['data'], validate=True)
            if data['digest'] != name or hashlib.sha256(chunk).hexdigest() != name:
                raise ValueError('Encrypted chunk digest mismatch')
            chunks[name] = chunk
        return response['revision'], unseal(manifest, chunks, password, vault)


def main():
    parser = argparse.ArgumentParser(description='SSH Hub Sync reference client (explicit files only)')
    parser.add_argument('--host', required=True)
    parser.add_argument('--known-hosts')
    parser.add_argument('--identity')
    parser.add_argument('--port', type=int, default=22)
    sub = parser.add_subparsers(dest='op', required=True)
    sub.add_parser('status')
    for name in ['head', 'history', 'push', 'pull']:
        item = sub.add_parser(name)
        item.add_argument('--vault', required=True)
        if name == 'push':
            item.add_argument('--input', type=Path, required=True)
            item.add_argument('--expected', type=int, required=True)
        if name == 'pull':
            item.add_argument('--output', type=Path, required=True)
            item.add_argument('--revision', type=int, default=0)
    args = parser.parse_args()
    remote = Remote(args.host, args.known_hosts, args.identity, args.port)
    if args.op == 'status':
        print(json.dumps(remote.request('status')))
    elif args.op in ('head', 'history'):
        print(json.dumps(remote.request(args.op, vault=args.vault)))
    else:
        password = getpass.getpass('Vault password (not sent to server): ')
        if args.op == 'push':
            if args.expected < 0:
                raise ValueError('Invalid expected revision')
            if password != getpass.getpass('Repeat vault password: '):
                raise ValueError('Passwords differ')
            if args.input.is_symlink() or not args.input.is_file() or not 1 <= args.input.stat().st_size <= MAXIMUM:
                raise ValueError('Choose a regular file up to 350 MB')
            print(json.dumps(remote.push(args.input.read_bytes(), password, args.vault, args.expected)))
        else:
            if args.output.exists() or args.output.is_symlink():
                raise ValueError('Output exists; choose a new file')
            revision, plain = remote.pull(password, args.vault, args.revision)
            fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as output:
                output.write(plain)
                output.flush(); os.fsync(output.fileno())
            print(json.dumps({'revision': revision, 'saved': str(args.output)}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Keep decryption failures secret-free (no plaintext/context dump).
        print('Sync failed: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
