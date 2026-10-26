"""Owned fake CLI fixtures exercise the real supervisor and local SSH runner.
No Lynis audit of the developer machine, registry pulls or user endpoints.
"""
import base64
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import socket
import shlex
import threading
import unicodedata
import signal


def ssh_fixture(root, wrapper):
    import paramiko
    key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    port = listener.getsockname()[1]
    known = root / 'known_hosts'
    known.write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    config = root / 'config'
    config.write_text(f'Host owned-audit\n HostName 127.0.0.1\n User fixture\n Port {port}\n UserKnownHostsFile {known}\n StrictHostKeyChecking yes\n')
    stopped = threading.Event()
    sessions = []

    class Server(paramiko.ServerInterface):
        def check_auth_none(self, username):
            return paramiko.AUTH_SUCCESSFUL if username == 'fixture' else paramiko.AUTH_FAILED

        def check_channel_request(self, kind, chanid):
            return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        def check_channel_exec_request(self, channel, command):
            def execute():
                args = shlex.split(command.decode())
                if len(args) != 4 or args[:2] != ['python3', '-c'] or unicodedata.normalize('NFC', args[2]) != unicodedata.normalize('NFC', (root / 'helper.py').read_text()):
                    channel.send_exit_status(64)
                    channel.close()
                    return
                proc = subprocess.Popen(['/usr/bin/python3', str(wrapper), args[3]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

                def input_pump():
                    try:
                        while True:
                            data = channel.recv(4096)
                            if not data:
                                break
                            proc.stdin.write(data)
                            proc.stdin.flush()
                    finally:
                        proc.stdin.close()

                def errors():
                    data = proc.stderr.read()
                    if data:
                        channel.sendall_stderr(data)

                threading.Thread(target=input_pump, daemon=True).start()
                threading.Thread(target=errors, daemon=True).start()
                try:
                    while True:
                        data = proc.stdout.read(65536)
                        if not data:
                            break
                        channel.sendall(data)
                    channel.send_exit_status(proc.wait(timeout=5))
                    channel.shutdown_write()
                finally:
                    channel.close()
            threading.Thread(target=execute, daemon=True).start()
            return True

    def accept():
        while not stopped.is_set():
            try:
                sock, _ = listener.accept()
            except OSError:
                return
            transport = paramiko.Transport(sock)
            sessions.append(transport)
            transport.add_server_key(key)
            transport.start_server(server=Server())
            channel = transport.accept(5)
            if channel is not None:
                sessions.append(channel)

    threading.Thread(target=accept, daemon=True).start()

    def close():
        stopped.set()
        listener.close()
        for session in sessions:
            session.close()
    return config, close


FAKE = r'''#!/usr/bin/python3
import os,sys,json,time,subprocess,signal,pathlib
root=pathlib.Path(__file__).parent;engine=pathlib.Path(__file__).name
args=sys.argv[1:];(root/('args-'+engine+'.json')).write_text(json.dumps(args))
report=pathlib.Path(args[args.index('--report-file' if engine=='lynis' else '--output')+1])
if engine=='lynis':
 report.write_text('lynis_version=3.1.8\nwarning[]=TEST-1000|Synthetic warning|password=hidden|url:https://invalid\nsuggestion[]=TEST-2000|Synthetic suggestion|-|-|\nhardening_index=65\nreport_datetime_end=2026-01-01\n')
else:
 if args[-1]=='bad':report.write_text('not-json');sys.exit(0)
 data={'SchemaVersion':2,'ArtifactName':'fixture','Results':[{'Target':'fixture','Vulnerabilities':[{'VulnerabilityID':'CVE-2025-12345','PkgName':'fixture-package','InstalledVersion':'1','FixedVersion':'2','Severity':'HIGH','Title':'Synthetic vulnerability','CVSS':{'fixture':{'V3Score':8.1}},'Description':'do-not-export-description','Secret':'do-not-export-secret'}],'Misconfigurations':[{'ID':'TEST-001','Title':'Synthetic config finding','Severity':'MEDIUM','Resolution':'Use an explicit version','CauseMetadata':{'Code':{'Lines':['do-not-export-code']}}}]}]}
 if args[-1]=='large':
  item=dict(data['Results'][0]['Vulnerabilities'][0],Title='測'*500,PkgName='試'*500)
  data['Results'][0]['Vulnerabilities']=[item]*2000;data['Results'][0]['Misconfigurations']=[]
 report.write_text(json.dumps(data))
 if args[-1] in ('slow','orphan'):
  child=subprocess.Popen(['/usr/bin/python3','-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'])
  (root/'child.pid').write_text(str(child.pid))
  if args[-1]=='slow':signal.signal(signal.SIGTERM,signal.SIG_IGN)
  time.sleep(30)
'''


def prepare(root, binary):
    root = pathlib.Path(root)
    subprocess.run([binary, '--helper', str(root / 'helper.py')], check=True)
    compile((root / 'helper.py').read_text(), 'helper.py', 'exec')
    for engine in ('lynis', 'trivy'):
        path = root / engine
        path.write_text(FAKE)
        path.chmod(0o700)
    wrapper = root / 'wrapper.py'
    wrapper.write_text('''import pathlib,shutil,tempfile,os,unittest.mock
root=pathlib.Path(__file__).parent
tempfile.tempdir=str(root)
with unittest.mock.patch('shutil.which',side_effect=lambda name,**kwargs:str(root/name)),unittest.mock.patch('os.geteuid',return_value=1000):
 exec(compile((root/'helper.py').read_text(),'helper.py','exec'))
''')
    return wrapper


def assert_stopped(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], text=True, capture_output=True)
    assert not result.stdout.strip() or result.stdout.strip().startswith('Z'), (pid, result.stdout)


def main():
    binary = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix='security-checks-fixture-') as folder:
        root = pathlib.Path(folder)
        wrapper = prepare(root, binary)
        for tool, action, status in [('fixture:1', 'run', 'completed'), ('lynis', 'run', 'limited'),
                                     ('slow', 'stop', 'stopped'), ('orphan', 'stop', 'stopped'), ('slow', 'timeout', 'stopped'), ('bad', 'run', 'failed'), ('large', 'run', 'limited')]:
            output = root / 'reply.json'
            start = time.monotonic()
            subprocess.run([binary, '--remote', str(wrapper), tool, action, str(output)], check=True, timeout=12)
            reply = json.loads(output.read_text())
            assert reply['status'] == status, reply
            if tool == 'large':
                assert 0 < len(reply['rows']) < 2000 and output.stat().st_size <= 7500000
            if tool in ('fixture:1', 'slow'):
                assert reply['rows'][0]['cves'] == ['CVE-2025-12345']
                assert reply['rows'][0]['score'] == 8.1
                assert len(reply['rows']) == 2
            if action in ('stop', 'timeout'):
                assert time.monotonic() - start < 5
                assert_stopped(int((root / 'child.pid').read_text()))
            assert not any(value in output.read_text() for value in
                           ['do-not-export-secret', 'do-not-export-description', 'do-not-export-code', 'password=hidden'])
            assert not list(root.glob('ssh-hub-audit-*')), 'supervisor temporary files not cleaned'
        args = json.loads((root / 'args-trivy.json').read_text())
        assert args[args.index('--scanners') + 1] == 'vuln,misconfig'
        assert args[args.index('--parallel') + 1] == '1'
        assert '--config' in args and '--ignorefile' in args
        args = json.loads((root / 'args-lynis.json').read_text())
        assert '--no-plugins' in args and '--profile' in args and '--report-file' in args
        held = root / 'held-pipe.py'
        held.write_text('''import subprocess,pathlib,json
root=pathlib.Path(__file__).parent
child=subprocess.Popen(['/usr/bin/python3','-c','import time;time.sleep(30)'])
(root/'held.pid').write_text(str(child.pid))
print(json.dumps(dict(schema=1,engine='trivy',status='completed',message='Fixture',rows=[])),flush=True)
''')
        try:
            start = time.monotonic()
            subprocess.run([binary, '--remote', str(held), 'fixture:1', 'run', str(root/'held.json')], check=True, timeout=3)
            assert time.monotonic() - start < 2, 'inherited output pipe blocked runner cleanup'
        finally:
            if (root/'held.pid').exists():
                try: os.kill(int((root/'held.pid').read_text()), signal.SIGKILL)
                except ProcessLookupError: pass
        if '--ssh' in sys.argv[2:]:
            config, close = ssh_fixture(root, wrapper)
            try:
                for target, action in [('fixture:1', 'run'), ('slow', 'stop')]:
                    subprocess.run([binary, '--ssh', str(config), target, action, str(root / 'ssh-reply.json')], check=True, timeout=15)
                assert_stopped(int((root / 'child.pid').read_text()))
            finally:
                close()
    print('PASS remote supervisor: Lynis/Trivy parsing, no raw secrets/config, EOF stop, timeout, child-group cleanup')


if __name__ == '__main__':
    main()
