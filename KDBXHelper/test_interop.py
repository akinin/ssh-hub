"""Independent owned KDBX 3.1 fixture, using the documented hashed-block format.
Only tests need Python cryptography; the shipped helper has no Python dependency.
"""
import base64, hashlib, json, pathlib, struct, subprocess, sys, tempfile, uuid
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
sha = lambda value: hashlib.sha256(value).digest()
def fixture():
    master, transform, iv, stream = bytes(range(32)), bytes(range(32,64)), bytes(range(16)), bytes(range(64,96))
    block = lambda kind, data: bytes([kind]) + struct.pack('<H', len(data)) + data
    header = struct.pack('<III', 0x9aa2d903, 0xb54bfb67, 0x00030001)
    for kind,data in [(2,bytes.fromhex('31c1f2e6bf714350be5805216afc5aff')),(3,struct.pack('<I',0)),(4,master),(5,transform),(6,struct.pack('<Q',1000)),(7,iv),(8,bytes([11])*32),(9,stream),(10,struct.pack('<I',2)),(0,b'\r\n\r\n')]: header += block(kind,data)
    uid = base64.b64encode(uuid.UUID('11111111-2222-3333-4444-555555555555').bytes).decode()
    xml = f'''<?xml version="1.0" encoding="utf-8"?><KeePassFile><Meta><Generator>Owned SSH Hub interoperability fixture</Generator><HeaderHash>{base64.b64encode(sha(header)).decode()}</HeaderHash></Meta><Root><Group><UUID>{uid}</UUID><Name>Owned fixture</Name><Entry><UUID>{base64.b64encode(uuid.UUID('22222222-3333-4444-5555-666666666666').bytes).decode()}</UUID><String><Key>Title</Key><Value>Independent KDBX3 fixture</Value></String><String><Key>UserName</Key><Value>fixture</Value></String><String><Key>Password</Key><Value>owned-v3-fixture-password</Value></String></Entry></Group></Root></KeePassFile>'''.encode()
    transformed = sha(sha(b'owned-v3-master'))
    aes = Cipher(algorithms.AES(transform), modes.ECB()).encryptor()
    for _ in range(1000): transformed = aes.update(transformed)
    key = sha(master + sha(transformed))
    body = stream + struct.pack('<I',0) + sha(xml) + struct.pack('<I',len(xml)) + xml + struct.pack('<I',1) + bytes(32) + struct.pack('<I',0)
    pad = 16 - len(body)%16; body += bytes([pad])*pad
    aes = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return header + aes.update(body) + aes.finalize()
def call(helper, path, master):
    process = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    request = {'id':'open','op':'open','path':str(path),'master_password':master}
    process.stdin.write(json.dumps(request).encode()+b'\n');process.stdin.flush()
    response = json.loads(process.stdout.readline()); secret = None
    if response['ok']:
        request = {'id':'read','op':'read','entry_id':response['result']['entries'][0]['id']}
        process.stdin.write(json.dumps(request).encode()+b'\n');process.stdin.flush(); secret=json.loads(process.stdout.readline())
        assert response['result']['writable'] is False
        draft=dict(title='Must not write',username='fixture',password='owned',url='',notes='',group_id='11111111-2222-3333-4444-555555555555')
        process.stdin.write(json.dumps(dict(id='save',op='save',draft=draft)).encode()+b'\n');process.stdin.flush()
        assert json.loads(process.stdout.readline()).get('code')=='read_only_format'
    process.stdin.close(); process.wait(timeout=3)
    assert not process.stderr.read()
    return response, secret
with tempfile.TemporaryDirectory(prefix='ssh-hub-kdbx3-owned-') as root:
    path = pathlib.Path(root)/'own.kdbx'; data=fixture();path.write_bytes(data)
    response,secret = call(sys.argv[1], path, 'owned-v3-master')
    assert response['ok'], response
    assert secret['result']['password']=='owned-v3-fixture-password'
    assert 'owned-v3-fixture-password' not in json.dumps(response)
    assert not call(sys.argv[1],path,'wrong')[0]['ok']
    assert path.read_bytes()==data
    broken=bytearray(data);broken[-20]^=1;path.write_bytes(broken)
    assert not call(sys.argv[1],path,'owned-v3-master')[0]['ok']
print('KDBX 3.1 independent fixture interoperability passed')
