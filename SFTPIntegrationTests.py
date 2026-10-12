#!/usr/bin/env python3
"""Real localhost SSH/SFTP tests using disposable keys; no third-party packages."""
import pathlib
import subprocess
import sys
import tempfile
from TunnelIntegrationTests import fixture


def main():
    binary = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='sftp-integration-', dir='/private/tmp') as directory:
        root = pathlib.Path(directory)
        with fixture(root) as (config, _, inherited_port):
            for alias in ['tunnel-test', 'through-hop']:
                remote = root / (alias + '-remote'); remote.mkdir()
                local = root / (alias + '-local'); local.mkdir()
                result = subprocess.run([str(binary), '--ssh', str(config), alias, str(remote), str(local)], capture_output=True, text=True, timeout=40)
                assert result.returncode == 0, result.stdout + result.stderr
                print(result.stdout.strip())
            assert not (root / 'should-not-exist').exists(), 'Inherited LocalCommand executed'
            from TunnelIntegrationTests import reachable
            assert not reachable(inherited_port), 'Inherited LocalForward opened'
            unknown = root / 'unknown-config'
            unknown.write_text(config.read_text().replace(str(root / 'known_hosts'), str(root / 'empty_known_hosts')))
            wrong = root / 'wrong-config'
            wrong.write_text(config.read_text().replace(str(root / 'client'), str(root / 'wrong')))
            known_before = (root / 'known_hosts').read_bytes()
            for rejected in [unknown, wrong]:
                result = subprocess.run([str(binary), '--reject-ssh', str(rejected), 'through-hop'], capture_output=True, text=True, timeout=12)
                assert result.returncode == 0, result.stdout + result.stderr
                print(result.stdout.strip())
            assert (root / 'known_hosts').read_bytes() == known_before
            assert (root / 'empty_known_hosts').read_bytes() == b''
    print('PASS: real SSH SFTP, ProxyJump, exact data, no inherited forwards/commands, auth/host-key rejection and cleanup')


if __name__ == '__main__':
    main()
