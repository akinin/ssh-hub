#!/usr/bin/env python3
"""Optional localhost-only integration tests. Requires macOS sshd and the built tunnel-tests binary."""
import contextlib
import getpass
import http.server
import pathlib
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time


def free_port():
    with socket.socket() as stream:
        stream.bind(('127.0.0.1', 0))
        return stream.getsockname()[1]


def reachable(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.2):
            return True
    except OSError:
        return False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'SSH-ALIASES-TUNNEL-OK'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass


@contextlib.contextmanager
def fixture(root, sftp_directory=None):
    root.mkdir(parents=True, exist_ok=True)
    daemon = None
    http_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()
    secrets = []
    try:
        for name in ['host', 'client', 'wrong']:
            key = root / name
            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'Disposable tunnel test', '-f', str(key)], check=True)
            secrets.extend([key, key.with_suffix('.pub')])
        ssh_port = free_port()
        sshd_config = root / 'sshd_config'
        sftp_home = str(sftp_directory or root).replace('\\', '\\\\').replace('"', '\\"')
        sshd_config.write_text(f'Port {ssh_port}\nListenAddress 127.0.0.1\nHostKey {root}/host\nPidFile {root}/pid\nAuthorizedKeysFile {root}/client.pub\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers {getpass.getuser()}\nAllowTcpForwarding yes\nSubsystem sftp internal-sftp -d "{sftp_home}"\nLogLevel ERROR\n')
        with (root / 'sshd.log').open('w') as log:
            daemon = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(sshd_config)], stdout=log, stderr=log)
        deadline = time.monotonic() + 3
        while not reachable(ssh_port):
            if daemon.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError((root / 'sshd.log').read_text())
            time.sleep(.05)
        public = (root / 'host.pub').read_text().split()
        known = root / 'known_hosts'
        known.write_text(f'[127.0.0.1]:{ssh_port} {public[0]} {public[1]}\n')
        (root / 'empty_known_hosts').write_text('')
        unused = free_port()
        common = f' HostName 127.0.0.1\n Port {ssh_port}\n User {getpass.getuser()}\n IdentityFile "{root}/client"\n IdentitiesOnly yes\n UserKnownHostsFile "{known}"\n'
        config = root / 'config'
        config.write_text('Host tunnel-test\n' + common + f' LocalForward {unused} 127.0.0.1:{http_server.server_port}\n RemoteCommand /usr/bin/false\n ForkAfterAuthentication yes\n ControlPersist yes\n PermitLocalCommand yes\n LocalCommand /usr/bin/touch "{root}/should-not-exist"\nHost through-hop\n' + common + ' ProxyJump hop\nHost hop\n' + common)
        config.chmod(0o600)
        yield config, http_server.server_port, unused
    finally:
        http_server.shutdown(); http_server.server_close()
        if daemon and daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=3)
            except subprocess.TimeoutExpired:
                daemon.kill(); daemon.wait()
        for path in secrets:
            path.unlink(missing_ok=True)


@contextlib.contextmanager
def session(binary, config, port, mode, target, stop, alias='tunnel-test', expect_active=True):
    stop.unlink(missing_ok=True)
    process = subprocess.Popen([str(binary), '--session', str(config), alias, str(port), mode, '127.0.0.1', str(target), str(stop)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    pending = queue.Queue()
    def read_output():
        for line in process.stdout:
            lines.append(line); pending.put(line)
    threading.Thread(target=read_output, daemon=True).start()
    try:
        if expect_active:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                try:
                    line = pending.get(timeout=.2)
                    if line.startswith('STATE Работает'):
                        break
                except queue.Empty:
                    if process.poll() is not None:
                        raise AssertionError(''.join(lines))
            else:
                raise AssertionError('Tunnel startup timed out: ' + ''.join(lines))
        yield process, lines
    finally:
        stop.touch()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(); raise AssertionError('Tunnel did not stop')
        time.sleep(.05)
        if expect_active:
            assert process.returncode == 0, ''.join(lines)
            deadline = time.monotonic() + 1
            while reachable(port) and time.monotonic() < deadline:
                time.sleep(.05)
            assert not reachable(port), 'Forward still listening after stop'


def response(stream):
    stream.sendall(b'GET / HTTP/1.0\r\nHost: test\r\n\r\n')
    data = b''
    while True:
        part = stream.recv(4096)
        if not part:
            break
        data += part
    assert b'SSH-ALIASES-TUNNEL-OK' in data, data


def main(binary):
    root = pathlib.Path(tempfile.mkdtemp(prefix='ti-', dir='/private/tmp'))
    try:
        with fixture(root) as (config, target, unused):
            with session(binary, config, free_port(), 'local', target, root / 'stop-local') as (process, lines):
                port = int(process.args[4])
                with socket.create_connection(('127.0.0.1', port), timeout=3) as stream:
                    response(stream)
                assert not reachable(unused), 'Config forwarding unexpectedly active'
                assert not (root / 'should-not-exist').exists(), 'LocalCommand unexpectedly executed'
            print('PASS: actual SSH local forwarding, exact HTTP payload, no inherited forwards/remote/local commands, stop releases port')
            port = free_port()
            with session(binary, config, port, 'socks', target, root / 'stop-socks', alias='through-hop'):
                with socket.create_connection(('127.0.0.1', port), timeout=3) as stream:
                    stream.sendall(b'\x05\x01\x00'); assert stream.recv(2) == b'\x05\x00'
                    stream.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + target.to_bytes(2, 'big'))
                    result = b''
                    while len(result) < 10:
                        result += stream.recv(10 - len(result))
                    assert result[1] == 0, result
                    response(stream)
            print('PASS: actual SOCKS5 through ProxyJump, exact HTTP payload and stop')
            with socket.socket() as occupied:
                occupied.bind(('127.0.0.1', 0)); occupied.listen()
                port = occupied.getsockname()[1]
                with session(binary, config, port, 'local', target, root / 'stop-busy', expect_active=False) as (process, lines):
                    process.wait(timeout=10)
                    assert process.returncode == 1 and not any(line.startswith('STATE Работает') for line in lines), ''.join(lines)
            untrusted = root / 'untrusted-config'
            untrusted.write_text(config.read_text().replace(str(root / 'known_hosts'), str(root / 'empty_known_hosts')))
            with session(binary, untrusted, free_port(), 'local', target, root / 'stop-untrusted', expect_active=False) as (process, lines):
                process.wait(timeout=10)
                assert process.returncode == 1 and not any(line.startswith('STATE Работает') for line in lines), ''.join(lines)
            assert (root / 'empty_known_hosts').read_bytes() == b''
            wrong = root / 'wrong-config'
            wrong.write_text(config.read_text().replace(str(root / 'client'), str(root / 'wrong')))
            with session(binary, wrong, free_port(), 'local', target, root / 'stop-auth', expect_active=False) as (process, lines):
                process.wait(timeout=10)
                assert process.returncode == 1 and not any(line.startswith('STATE Работает') for line in lines), ''.join(lines)
            print('PASS: occupied port, unknown host key and incorrect identity fail without false active status or known_hosts changes')
    finally:
        shutil.rmtree(root)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture':
        root = pathlib.Path(sys.argv[2]).resolve()
        with fixture(root) as (config, target, unused):
            print(f'FIXTURE {config} TARGET {target}', flush=True)
            while not (root / 'stop-fixture').exists():
                time.sleep(.1)
    elif len(sys.argv) == 2:
        main(pathlib.Path(sys.argv[1]).resolve())
    else:
        raise SystemExit('Usage: python3 Tests/TunnelIntegrationTests.py /path/to/tunnel-tests')
