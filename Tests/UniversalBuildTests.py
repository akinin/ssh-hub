"""Validate every shipped CPU slice; --smoke runs only on a disposable CI Mac."""
import argparse
import hashlib
import os
import pathlib
import platform
import plistlib
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--notarized', action='store_true', help='Require an offline notarization ticket and Gatekeeper acceptance')
parser.add_argument('--smoke', action='store_true', help='Run owned helpers and an empty-config app on a disposable CI runner only')
args = parser.parse_args()
app = args.app.resolve()
expected = {'SSHHub', 'SSHAskpass', 'SSHLoginAskpass', 'SSHKDBX', 'SSHRDP', 'SSHSerial', 'SSHTelnet', 'SSHUpdate', 'SSHWG'}
macos = app/'Contents/MacOS'
assert {p.name for p in macos.iterdir()} == expected
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.olshaniki.ssh-aliases'
assert info['LSMinimumSystemVersion'] == '14.0'
assert not (app/'Contents/Resources/SSHHub-CodeSigning.cer').exists(), 'Legacy self-signed certificate must not ship'
team = 'T3V8ZUE97C'
policy = 'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"' + team + '\"'

def run(*command):
    return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True, timeout=30)

machos = []
for path in app.rglob('*'):
    if not path.is_file():
        continue
    with path.open('rb') as handle:
        magic = handle.read(4)
    if magic not in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca']:
        continue
    machos.append(path)
    assert set(run('/usr/bin/lipo', '-archs', str(path)).split()) == {'arm64', 'x86_64'}, path
    for architecture in ['arm64', 'x86_64']:
        run('/usr/bin/codesign', '--verify', '--strict', '--architecture', architecture, str(path))
        requirement = run('/usr/bin/codesign', '-d', '-r-', '--architecture', architecture, str(path))
        assert team in requirement and 'cdhash' not in requirement, path
        identifier = info['CFBundleIdentifier'] + ('.helper.' + path.name if path.name != 'SSHHub' else '')
        run('/usr/bin/codesign', '--verify', '--strict', '--architecture', architecture, '-R', '=identifier \"' + identifier + '\" and ' + policy, str(path))
        metadata = run('/usr/bin/codesign', '-d', '--verbose=4', '--architecture', architecture, str(path))
        assert '(runtime)' in metadata and 'Timestamp=' in metadata and ('TeamIdentifier=' + team) in metadata, path
        if path.name != 'SSHHub':
            entitlements = subprocess.check_output(['/usr/bin/codesign', '-d', '--architecture', architecture, '--entitlements', ':-', str(path)], stderr=subprocess.DEVNULL)
            assert not entitlements or not plistlib.loads(entitlements), 'Helpers must not receive main app Keychain rights'
        libraries = run('/usr/bin/otool', '-arch', architecture, '-L', str(path))
        dependencies = '\n'.join(line for line in libraries.splitlines() if line.startswith('\t'))
        assert not any(p in dependencies for p in ['/opt/homebrew/', '/usr/local/', '/private/tmp/', '/Users/']), path
assert len(machos) == len(expected)
run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
run(sys.executable, 'Scripts/signing-profile.py', '--app', str(app))
print('Universal validation passed: all 9 binaries have signed arm64/x86_64 slices; Apple Developer ID team, Hardened Runtime, secure timestamps; portable dependencies.')

if args.notarized:
    run('/usr/bin/xcrun', 'stapler', 'validate', str(app))
    run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))
    print('Notarization validation passed: stapled app ticket and Gatekeeper acceptance.')

if args.smoke:
    # Refuse accidental execution against a developer/user Mac.
    assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    tokens = {'GH_TOKEN', 'GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'}
    environment = {k: v for k, v in os.environ.items() if k not in tokens and not k.startswith(('SSH_', 'SSH_HUB_', 'SSH_ALIASES_'))}
    for name in sorted(expected - {'SSHHub'}):
        result = subprocess.run([str(macos/name)], input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, env=environment)
        assert result.returncode in (0, 1, 2), (name, result.returncode)
    with tempfile.TemporaryDirectory(prefix='ssh-hub-universal-smoke-') as temporary:
        config = pathlib.Path(temporary)/'config'
        config.write_text('')
        config.chmod(0o600)
        subprocess.run(['/usr/bin/defaults', 'write', 'com.olshaniki.ssh-aliases', 'checkUpdatesOnLaunch.v1', '-bool', 'false'], check=True)
        process = subprocess.Popen([str(macos/'SSHHub'), '--config', str(config)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=environment)
        try:
            time.sleep(6)
            assert process.poll() is None, ('App startup failed', process.returncode, process.stderr.read(4096))
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
    print('Native smoke passed on ' + platform.machine() + ': all helpers execute and app remains running with an owned empty config.')
