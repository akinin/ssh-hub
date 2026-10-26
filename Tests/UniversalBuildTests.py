"""Validate every shipped CPU slice; --smoke runs only on a disposable CI Mac."""
import argparse
import hashlib
import os
import pathlib
import platform
import plistlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--smoke', action='store_true', help='Run owned helpers and an empty-config app on a disposable CI runner only')
args = parser.parse_args()
app = args.app.resolve()
expected = {'SSHHub', 'SSHAskpass', 'SSHLoginAskpass', 'SSHKDBX', 'SSHRDP', 'SSHSerial', 'SSHTelnet', 'SSHUpdate', 'SSHWG'}
macos = app/'Contents/MacOS'
assert {p.name for p in macos.iterdir()} == expected
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.olshaniki.ssh-aliases'
assert info['LSMinimumSystemVersion'] == '14.0'
certificate = app/'Contents/Resources/SSHHub-CodeSigning.cer'
assert hashlib.sha256(certificate.read_bytes()).hexdigest() == '4e404f8eaed616350e2e759c11296408b0f863712ce11afa5a59f91511c2d684'

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
        assert '22f2efb2ae6b78efafcf8ad5c80cc0b040f610a5' in requirement.lower() and 'cdhash' not in requirement, path
        libraries = run('/usr/bin/otool', '-arch', architecture, '-L', str(path))
        dependencies = '\n'.join(line for line in libraries.splitlines() if line.startswith('\t'))
        assert not any(p in dependencies for p in ['/opt/homebrew/', '/usr/local/', '/private/tmp/', '/Users/']), path
assert len(machos) == len(expected)
run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
print('Universal validation passed: all 9 binaries have signed arm64/x86_64 slices; pinned public certificate; portable dependencies.')

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
