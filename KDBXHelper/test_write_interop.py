"""Owned KeePassXC round trips. No user database, profile or credentials are accessed."""
import json, os, pathlib, shutil, struct, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

cli = os.environ.get('SSH_HUB_KEEPASSXC_CLI') or shutil.which('keepassxc-cli')
if not cli and pathlib.Path('/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli').is_file():
    cli = '/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli'
if not cli:
    print('KeePassXC write interoperability not run: optional keepassxc-cli unavailable')
    sys.exit(0)
helper = sys.argv[1]
master = 'owned interop master'

def command(args, data):
    result = subprocess.run([cli] + list(map(str, args)), input=data.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    assert result.returncode == 0, 'owned KeePassXC command failed: ' + args[0]
    return result.stdout

class Worker:
    def __init__(self):
        self.p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def call(self, op, **fields):
        self.p.stdin.write(json.dumps(dict(id='owned', op=op, **fields)).encode() + b'\n'); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=3)
        assert not self.p.stderr.read(), 'helper must not log payloads'

def fields(e):
    return {s.findtext('Key'): s.findtext('Value') or '' for s in e.findall('String')}

for use_key in (False, True):
    with tempfile.TemporaryDirectory(prefix='ssh-hub-keepassxc-owned-') as temp:
        root = pathlib.Path(temp); db = root/'owned.kdbx'; key = root/'owned.key'
        key.write_bytes(bytes(range(32))); key_before = key.read_bytes()
        set_key = ['--set-key-file', key] if use_key else []
        key_args = ['-k', key] if use_key else []
        command(['db-create', '-q', '-p', '-t', '100', *set_key, db], master+'\n'+master+'\n')
        command(['add', '-q', *key_args, '-p', '-u', 'fixture', '--notes', 'original notes', db, 'Owned entry'], master+'\nowned original password\n')
        command(['edit', '-q', *key_args, '--notes', 'history before SSH Hub', db, 'Owned entry'], master+'\n')
        binary = root/'owned.bin'; binary.write_bytes(bytes(range(256)))
        command(['attachment-import', '-q', *key_args, db, 'Owned entry', 'owned.bin', binary], master+'\n')
        xml = ET.fromstring(command(['export', '-q', *key_args, db], master+'\n'))
        # Group tags are a KDBX4.1 feature; KeePassXC chooses the required format on import.
        group_node = xml.find('Root/Group')
        tags = group_node.find('Tags')
        if tags is None: tags = ET.SubElement(group_node, 'Tags')
        tags.text = 'owned-interoperability-tag'
        owned_entry = next(e for e in xml.findall('.//Root//Entry') if fields(e).get('Title')=='Owned entry')
        custom = ET.SubElement(owned_entry, 'String')
        ET.SubElement(custom, 'Key').text = 'SSH Hub owned custom field'
        ET.SubElement(custom, 'Value').text = 'custom value survives'
        source_xml = root/'owned-fixture.xml'; source_xml.write_bytes(ET.tostring(xml, encoding='utf-8', xml_declaration=True))
        source_xml.chmod(0o600)
        db = root/'owned-v4.kdbx'
        command(['import', '-q', '-p', '-t', '100', *set_key, source_xml, db], master+'\n'+master+'\n')
        before_xml = command(['export', '-q', *key_args, db], master+'\n')
        before_tree = ET.fromstring(before_xml)
        before_entry = next(e for e in before_tree.findall('.//Root//Entry') if fields(e).get('Title')=='Owned entry')
        uid = before_entry.findtext('UUID'); old_history = len(before_entry.findall('History/Entry'))
        before = db.read_bytes(); version = before[8:12]
        assert struct.unpack('<HH', version)[1] == 4
        worker = Worker()
        opened = worker.call('open', path=str(db), master_password=master, **({'key_path':str(key)} if use_key else {}))
        assert opened['ok'] and opened['result']['writable'], 'KeePassXC KDBX4 must be writable'
        catalog = opened['result']; record = next(e for e in catalog['entries'] if e['title']=='Owned entry')
        group = catalog['groups'][0]['id']
        draft = dict(title='Changed by SSH Hub', username='changed-user', password='owned updated password', url='https://example.invalid/?a=1&b=2', notes='Notes\nwith <markup> & unicode 😀', group_id=group)
        saved = worker.call('save', entry_id=record['id'], draft=draft)
        assert saved['ok'], saved.get('code')
        assert 'owned updated password' not in json.dumps(saved)
        assert db.read_bytes()[8:12] == version, 'format must not change'
        backup = root/saved['result']['backup_name']
        assert backup.read_bytes() == before and backup.stat().st_mode & 0o777 == 0o600
        assert not pathlib.Path(str(db)+'.lock').exists()
        after_xml = command(['export', '-q', *key_args, db], master+'\n')
        after_tree = ET.fromstring(after_xml)
        updated = next(e for e in after_tree.findall('.//Root//Entry') if e.findtext('UUID')==uid and fields(e).get('Title')=='Changed by SSH Hub')
        actual = fields(updated)
        for key_name, expected in [('UserName',draft['username']),('Password',draft['password']),('URL',draft['url']),('Notes',draft['notes'])]: assert actual[key_name] == expected
        assert actual['SSH Hub owned custom field'] == 'custom value survives'
        history = updated.findall('History/Entry')
        assert len(history) == old_history + 1
        assert any(fields(e).get('Password')=='owned original password' for e in history)
        assert ET.tostring(updated.find('Binary')) == ET.tostring(before_entry.find('Binary'))
        assert ET.tostring(after_tree.find('Meta/Binaries')) == ET.tostring(before_tree.find('Meta/Binaries')) if before_tree.find('Meta/Binaries') is not None else True
        # KeePassXC independently reads the unchanged binary payload, including references from history.
        target = root/'roundtrip.bin'
        command(['attachment-export', '-q', *key_args, db, 'Changed by SSH Hub', 'owned.bin', target], master+'\n')
        assert target.read_bytes() == binary.read_bytes()
        created = worker.call('save', draft={**draft, 'title':'New owned entry'})
        assert created['ok'] and created['result']['entry_id'] != record['id']
        command(['export', '-q', *key_args, db], master+'\n')
        # Reverse direction: an external KeePassXC edit must win over this worker's stale snapshot.
        command(['edit', '-q', *key_args, '--notes', 'changed externally in KeePassXC', db, 'Changed by SSH Hub'], master+'\n')
        external = db.read_bytes()
        conflict = worker.call('save', entry_id=record['id'], draft=draft)
        assert conflict.get('code')=='file_changed' and db.read_bytes()==external
        worker.close()
        again=Worker(); result=again.call('open', path=str(db), master_password=master, **({'key_path':str(key)} if use_key else {}))
        assert result['ok']
        read=again.call('read', entry_id=record['id']); assert read['result']['password']==draft['password']
        again.close(); assert key.read_bytes()==key_before
print('KeePassXC owned round trips passed: KDBX4 version unchanged, master/keyfile, UUID, fields, history, attachments, encrypted backup, create, external conflict')

# Independent KDBX4.0 AES-KDF/HMAC container (not emitted by keepass-rs).
import base64, hashlib, hmac, uuid
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
sha = lambda b: hashlib.sha256(b).digest()
salt, seed, iv = bytes(range(32)), bytes(range(32,64)), bytes(range(16))
def vd(kind, key, value):
    key=key.encode(); return bytes([kind])+struct.pack('<I',len(key))+key+struct.pack('<I',len(value))+value
kdf=struct.pack('<H',0x100)+vd(0x42,'$UUID',bytes.fromhex('c9d9f39a628a4460bf740d08c18a4fea'))+vd(0x42,'S',salt)+vd(5,'R',struct.pack('<Q',1000))+vd(4,'OwnedParam',struct.pack('<I',42))+b'\0'
tlv=lambda kind,value:bytes([kind])+struct.pack('<I',len(value))+value
header=struct.pack('<III',0x9aa2d903,0xb54bfb67,0x00040000)
for kind,value in [(2,bytes.fromhex('31c1f2e6bf714350be5805216afc5aff')),(3,struct.pack('<I',0)),(4,seed),(7,iv),(11,kdf),(0,b'\r\n\r\n')]: header+=tlv(kind,value)
gid=base64.b64encode(uuid.UUID('11111111-2222-3333-4444-555555555555').bytes).decode()
eid=base64.b64encode(uuid.UUID('22222222-3333-4444-5555-666666666666').bytes).decode()
xml=f'<KeePassFile><Meta><Generator>Independent owned fixture</Generator></Meta><Root><Group><UUID>{gid}</UUID><Name>Owned</Name><Entry><UUID>{eid}</UUID><String><Key>Title</Key><Value>Independent</Value></String><String><Key>UserName</Key><Value>fixture</Value></String><String><Key>Password</Key><Value>owned initial</Value></String><Binary><Key>owned.bin</Key><Value Ref="0"/></Binary></Entry></Group></Root></KeePassFile>'.encode()
payload=tlv(1,struct.pack('<I',2))+tlv(2,bytes(range(64)))+tlv(3,b'\x01'+bytes(range(256)))+tlv(0,b'')+xml
transformed=sha(sha(master.encode())); aes=Cipher(algorithms.AES(salt),modes.ECB()).encryptor()
for _ in range(1000): transformed=aes.update(transformed)
transformed=sha(transformed); outer=sha(seed+transformed); auth=hashlib.sha512(seed+transformed+b'\x01').digest()
def mac(index,data):
    key=hashlib.sha512(struct.pack('<Q',index)+auth).digest()
    return hmac.new(key,data,hashlib.sha256).digest()
pad=16-len(payload)%16; enc=Cipher(algorithms.AES(outer),modes.CBC(iv)).encryptor(); encrypted=enc.update(payload+bytes([pad])*pad)+enc.finalize()
def block(index,data): return mac(index,struct.pack('<QI',index,len(data))+data)+struct.pack('<I',len(data))+data
data=header+sha(header)+mac(0xffffffffffffffff,header)+block(0,encrypted)+block(1,b'')
with tempfile.TemporaryDirectory(prefix='ssh-hub-kdbx4-independent-') as temp:
    path=pathlib.Path(temp)/'owned.kdbx';path.write_bytes(data)
    worker=Worker(); opened=worker.call('open',path=str(path),master_password=master)
    assert opened['ok'] and opened['result']['writable']
    record=opened['result']['entries'][0]; group=opened['result']['groups'][0]['id']
    saved=worker.call('save',entry_id=record['id'],draft=dict(title='Independent updated',username='fixture',password='owned updated',url='',notes='',group_id=group))
    assert saved['ok'], saved.get('code')
    after=path.read_bytes();assert after[8:12]==data[8:12] and b'OwnedParam' in after
    assert b'owned updated' not in after
    exported=ET.fromstring(command(['export','-q',path],master+'\n'))
    updated=next(e for e in exported.findall('.//Root//Entry') if fields(e).get('Title')=='Independent updated')
    assert fields(updated)['Password']=='owned updated' and updated.findtext('UUID')==eid
    target=pathlib.Path(temp)/'owned.bin';command(['attachment-export','-q',path,'Independent updated','owned.bin',target],master+'\n')
    assert target.read_bytes()==bytes(range(256))
    worker.close()
    # Two independent workers opened the same revision: exactly one may commit.
    from concurrent.futures import ThreadPoolExecutor
    workers=[Worker(),Worker()]
    for w in workers: assert w.call('open',path=str(path),master_password=master)['ok']
    draft=dict(title='Concurrent owned edit',username='fixture',password='owned updated',url='',notes='',group_id=group)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda w:w.call('save',entry_id=record['id'],draft=draft),workers))
    assert sum(r['ok'] for r in results)==1
    assert next(r['code'] for r in results if not r['ok']) in ('database_busy','file_changed')
    for w in workers: w.close()
    assert command(['export','-q',path],master+'\n')
print('Independent KDBX4.0 write round trip passed: KeePassXC reads output, same version, KDF extension, protected attachment, UUID')
