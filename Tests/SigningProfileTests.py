"""Exercise profile policy with public, synthetic fixtures; no Keychain operations."""
import copy
import datetime
import hashlib
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('profile_policy', pathlib.Path(__file__).resolve().parents[1]/'Scripts/signing-profile.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ProfilePolicyTests(unittest.TestCase):
    def fixture(self):
        return {'TeamIdentifier': [policy.TEAM], 'Platform': ['OSX'],
                'ExpirationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=1),
                'ProvisionsAllDevices': True, 'DeveloperCertificates': [b'owned-public-certificate'],
                'Entitlements': copy.deepcopy(policy.ENTITLEMENTS)}

    def test_application_profile_and_renewed_certificate_are_accepted(self):
        p = self.fixture()
        policy.validate(p, hashlib.sha1(b'owned-public-certificate').hexdigest())
        p['DeveloperCertificates'] = [b'owned-renewed-public-certificate']
        policy.validate(p, hashlib.sha1(b'owned-renewed-public-certificate').hexdigest())

    def test_other_team_application_development_expiry_and_certificate_are_rejected(self):
        for mutate in [lambda p: p.update(TeamIdentifier=['OTHERTEAM']),
                       lambda p: p.update(Platform=['iOS']),
                       lambda p: p.update(ProvisionsAllDevices=False),
                       lambda p: p.update(ProvisionedDevices=['owned-device']),
                       lambda p: p.update(ExpirationDate=datetime.datetime(2020, 1, 1)),
                       lambda p: p['Entitlements'].update({'com.apple.application-identifier': policy.TEAM + '.other-app'}),
                       lambda p: p['Entitlements'].update({'keychain-access-groups': [policy.TEAM + '.other-app']}),
                       lambda p: p['Entitlements'].update({'get-task-allow': True}),
                       lambda p: p.update(DeveloperCertificates=[b'other-certificate'])]:
            with self.subTest(mutate=mutate):
                p = self.fixture(); mutate(p)
                with self.assertRaises(AssertionError):
                    policy.validate(p, hashlib.sha1(b'owned-public-certificate').hexdigest())


if __name__ == '__main__':
    unittest.main()
