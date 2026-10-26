#!/usr/bin/env python3
# coding: utf-8
"""Owned loopback sshd only; never reads user logs or changes user's SSH configuration."""
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
from TunnelIntegrationTests import fixture, reachable

with tempfile.TemporaryDirectory(prefix='ssh-hub-log-integration-', dir='/private/tmp') as folder:
    root = pathlib.Path(folder)
    with fixture(root / 'ssh') as (original, _, unused):
        known = root / 'ssh' / 'known_hosts'
        trusted_before = known.read_bytes()
        log = root / "fixture space'$(printf EXPANDED).log"
        log.write_text('fixture info: Привет 👋\n', encoding='utf-8')
        # Same prepended restrictions as TunnelCommands.temporaryConfig: ProxyJump's
        # helper ssh reads them too. The core wrapper itself has existing tunnel tests.
        prefix = '''Host *
 BatchMode yes
 StrictHostKeyChecking yes
 UpdateHostKeys no
 ControlMaster no
 ControlPath none
 ControlPersist no
 PermitLocalCommand no
 ForwardAgent no
 ForwardX11 no
 ForkAfterAuthentication no
 RemoteCommand none
 RequestTTY no
 ConnectTimeout 3
 ConnectionAttempts 1
'''
        protected = root / 'protected-config'
        protected.write_text(prefix + original.read_text())
        def run(config, alias, outcome):
            subprocess.run([sys.argv[1], str(config), alias, str(log), outcome], check=True, timeout=15)
        run(protected, 'tunnel-test', 'success')
        run(protected, 'through-hop', 'success')
        def append():
            time.sleep(.4)
            with log.open('a', encoding='utf-8') as stream:
                stream.write('fixture warning: appended\n'); stream.flush()
        thread = threading.Thread(target=append); thread.start()
        run(protected, 'tunnel-test', 'follow'); thread.join()
        untrusted = root / 'untrusted-config'
        untrusted.write_text(protected.read_text().replace(str(known), str(root / 'ssh' / 'empty_known_hosts')))
        run(untrusted, 'tunnel-test', 'failure')
        wrong = root / 'wrong-config'
        wrong.write_text(protected.read_text().replace(str(root / 'ssh' / 'client'), str(root / 'ssh' / 'wrong')))
        run(wrong, 'tunnel-test', 'failure')
        assert known.read_bytes() == trusted_before, 'log capture changed known_hosts'
        assert (root / 'ssh' / 'empty_known_hosts').read_bytes() == b'', 'unknown key accepted'
        assert not (root / 'ssh' / 'should-not-exist').exists(), 'inherited LocalCommand ran'
        assert not reachable(unused), 'inherited forwarding opened'
print('PASS Remote logs loopback SSH: snapshot, ProxyJump, Unicode/quoted path, live capture/deadline, unknown host/auth failure, no inherited local commands/forwards or trust changes')
