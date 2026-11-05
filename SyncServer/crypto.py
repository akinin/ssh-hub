"""Portable encrypted snapshot format; client side only, never installed on server.

Reference for the future Swift/Windows clients. cryptography is used for the
standard AES-256-GCM and PBKDF2-HMAC-SHA256 implementations, not custom crypto.
"""
import hashlib
import json
import os
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

MAGIC = b'SSHHUBS1'
ROUNDS = 600_000
CHUNK_SIZE = 4 * 1024 * 1024
MAXIMUM = 350_000_052


def scope(vault):
    if str(uuid.UUID(vault)) != vault:
        raise ValueError('Invalid vault ID')
    return vault.encode('ascii')


def key(password, salt):
    secret = password.encode('utf-8')
    if not 12 <= len(secret) <= 1024 or len(salt) != 16:
        raise ValueError('Vault password must be 12–1024 UTF-8 bytes')
    return PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=ROUNDS).derive(secret)


def seal(data, password, vault, expected=0):
    if not isinstance(data, bytes) or not 1 <= len(data) <= MAXIMUM:
        raise ValueError('Invalid snapshot size')
    if type(expected) is not int or not 0 <= expected < 2**53 - 1:
        raise ValueError('Invalid base revision')
    salt = os.urandom(16)
    cipher = AESGCM(key(password, salt))
    snapshot = str(uuid.uuid4())
    aad = scope(vault) + b'/' + snapshot.encode('ascii')
    chunks = []
    for index, offset in enumerate(range(0, len(data), CHUNK_SIZE)):
        nonce = os.urandom(12)
        encrypted = nonce + cipher.encrypt(nonce, data[offset:offset + CHUNK_SIZE], aad + b'/' + str(index).encode('ascii'))
        chunks.append((hashlib.sha256(encrypted).hexdigest(), encrypted))
    manifest = {'format': 1, 'snapshot': snapshot, 'revision': expected + 1, 'size': len(data),
                'sha256': hashlib.sha256(data).hexdigest(), 'chunks': [name for name, _ in chunks]}
    header = MAGIC + salt
    nonce = os.urandom(12)
    packet = header + nonce + cipher.encrypt(nonce, json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode(), header + scope(vault))
    return packet, chunks


def open_manifest(packet, password, vault):
    if not 52 <= len(packet) <= 1024 * 1024 or packet[:8] != MAGIC:
        raise ValueError('Invalid manifest')
    cipher = AESGCM(key(password, packet[8:24]))
    manifest = json.loads(cipher.decrypt(packet[24:36], packet[36:], packet[:24] + scope(vault)))
    if (type(manifest.get('format')) is not int or manifest['format'] != 1 or
            type(manifest.get('revision')) is not int or not 1 <= manifest['revision'] < 2**53 or
            type(manifest.get('size')) is not int or not 1 <= manifest['size'] <= MAXIMUM or
            str(uuid.UUID(manifest['snapshot'])) != manifest['snapshot'] or
            not isinstance(manifest.get('chunks'), list) or
            len(manifest['chunks']) != (manifest['size'] + CHUNK_SIZE - 1) // CHUNK_SIZE or
            len(set(manifest['chunks'])) != len(manifest['chunks']) or
            any(not isinstance(n, str) or len(n) != 64 or any(c not in '0123456789abcdef' for c in n) for n in manifest['chunks']) or
            not isinstance(manifest.get('sha256'), str) or len(manifest['sha256']) != 64):
        raise ValueError('Invalid manifest')
    return manifest, cipher


def unseal(packet, chunks, password, vault):
    manifest, cipher = open_manifest(packet, password, vault)
    if set(chunks) != set(manifest['chunks']):
        raise ValueError('Missing or unexpected chunks')
    aad = scope(vault) + b'/' + manifest['snapshot'].encode('ascii')
    data = bytearray()
    for index, name in enumerate(manifest['chunks']):
        encrypted = chunks[name]
        if not 29 <= len(encrypted) <= CHUNK_SIZE + 28 or hashlib.sha256(encrypted).hexdigest() != name:
            raise ValueError('Invalid encrypted chunk')
        plain = cipher.decrypt(encrypted[:12], encrypted[12:], aad + b'/' + str(index).encode('ascii'))
        expected = min(CHUNK_SIZE, manifest['size'] - index * CHUNK_SIZE)
        if len(plain) != expected:
            raise ValueError('Invalid chunk size')
        data.extend(plain)
    if len(data) != manifest['size'] or hashlib.sha256(data).hexdigest() != manifest['sha256']:
        raise ValueError('Invalid snapshot digest')
    return bytes(data)
