#!/usr/bin/env python3
"""Validate public Developer ID provisioning and the app's minimal Keychain rights."""
import argparse
import datetime
import hashlib
import pathlib
import plistlib
import subprocess
import tempfile

TEAM = 'T3V8ZUE97C'
BUNDLE = 'com.olshaniki.ssh-aliases'
APP_ID = TEAM + '.' + BUNDLE
ENTITLEMENTS = {'com.apple.application-identifier': APP_ID,
                'com.apple.developer.team-identifier': TEAM,
                'keychain-access-groups': [APP_ID]}


def permits(pattern, value):
    return pattern == value or (isinstance(pattern, str) and pattern.endswith('*')
                                and '*' not in pattern[:-1] and value.startswith(pattern[:-1]))


def validate(profile, identity=None):
    assert profile.get('TeamIdentifier') == [TEAM], 'Wrong provisioning team'
    assert 'OSX' in profile.get('Platform', []), 'A macOS profile is required'
    expiry = profile.get('ExpirationDate')
    assert isinstance(expiry, datetime.datetime) and expiry > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Provisioning profile expired'
    assert profile.get('ProvisionsAllDevices') is True and not profile.get('ProvisionedDevices'), 'A Developer ID distribution profile is required'
    rights = profile.get('Entitlements', {})
    assert not rights.get('get-task-allow') and not rights.get('com.apple.security.get-task-allow'), 'Development/debug profile is forbidden'
    assert rights.get('com.apple.developer.team-identifier') == TEAM, 'Wrong entitlement team'
    assert permits(rights.get('com.apple.application-identifier'), APP_ID), 'Profile does not authorize SSH Hub'
    assert any(permits(group, APP_ID) for group in rights.get('keychain-access-groups', [])), 'Profile does not authorize the private Keychain group'
    certificates = profile.get('DeveloperCertificates', [])
    assert certificates, 'Profile contains no signing certificate'
    if identity:
        assert identity.upper() in {hashlib.sha1(cert).hexdigest().upper() for cert in certificates}, 'Profile does not include the selected Developer ID certificate'


def read_profile(path):
    assert path.is_file() and not path.is_symlink(), 'Missing or linked provisioning profile'
    # security cms validates the signed profile; never parse an unverified plist instead.
    return plistlib.loads(subprocess.check_output(['/usr/bin/security', 'cms', '-D', '-i', str(path)], stderr=subprocess.PIPE, timeout=30))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=pathlib.Path)
    parser.add_argument('--identity')
    parser.add_argument('--app', type=pathlib.Path)
    args = parser.parse_args()
    if args.app:
        app = args.app
        profile = read_profile(app/'Contents/embedded.provisionprofile')
        validate(profile, args.identity)
        for arch in ['arm64', 'x86_64']:
            raw = subprocess.check_output(['/usr/bin/codesign', '-d', '--architecture', arch, '--entitlements', ':-', str(app)], stderr=subprocess.PIPE, timeout=30)
            assert plistlib.loads(raw) == ENTITLEMENTS, 'Unexpected or missing main app entitlements: ' + arch
            with tempfile.TemporaryDirectory(prefix='ssh-hub-public-signing-certificate-') as folder:
                prefix = str(pathlib.Path(folder)/'certificate-')
                subprocess.run(['/usr/bin/codesign', '-d', '--architecture', arch, '--extract-certificates=' + prefix, str(app)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
                leaf = pathlib.Path(prefix + '0').read_bytes()
                validate(profile, hashlib.sha1(leaf).hexdigest())
    else:
        assert args.profile and args.identity, '--profile and --identity are required'
        validate(read_profile(args.profile), args.identity)
    print('Developer ID provisioning and private SSH Hub Keychain group verified')


if __name__ == '__main__':
    main()
