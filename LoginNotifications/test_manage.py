#!/usr/bin/env python3
"""Manager tests using private prefix roots and fake systemctl, never host files."""
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("login_manage_fixture", HERE / "manage.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)
TOKEN = "123456789:" + "a" * 35
NEXT_TOKEN = "987654321:" + "b" * 35
PAM = b"# Synthetic PAM fixture\n@include common-auth\nsession required pam_limits.so\n"


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("etc/pam.d", "etc/ssh", "usr/local/lib", "usr/local/sbin", "etc/systemd/system", "var/lib"):
            path = self.root / name
            path.mkdir(parents=True, exist_ok=True)
            current = path
            while current != self.root:
                current.chmod(0o755)
                current = current.parent
        self.write(manage.PAM, PAM, 0o644)
        self.commands = []

    def write(self, relative, data, mode=0o600):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, str):
            data = data.encode()
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def config(self, **updates):
        value = {"chat_id": "-1001234567890", "host_label": "Fixture host", "tag": "lab"}
        value.update(updates)
        return value

    def payload(self, action, **updates):
        value = {"schema": 1, "action": action, "expected_revision": manage.inspect(self.root)["revision"]}
        if action == "install":
            helper = (HERE / "notify.py").read_bytes()
            value.update(config=self.config(), token=TOKEN, helper=base64.b64encode(helper).decode(), helper_sha256=hashlib.sha256(helper).hexdigest())
        value.update(updates)
        return value

    def execute(self, payload, command=None, preflight=None):
        return manage.execute(payload, root=self.root, command=command or self.commands.append, preflight=preflight or (lambda: None))

    def install(self):
        return self.execute(self.payload("install"))

    def assert_failure(self, code, payload, **keywords):
        with self.assertRaises(manage.Failure) as caught:
            self.execute(payload, **keywords)
        self.assertEqual(caught.exception.code, code)

    def observed(self):
        return {name: (self.root / name).read_bytes() if (self.root / name).is_file() else None for name in manage.OBSERVED}

    def assert_private(self, value):
        text = json.dumps(value, ensure_ascii=False)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn(NEXT_TOKEN, text)
        self.assertNotIn("api.telegram.org/bot", text)

    def test_inspect_is_read_only_absent_and_does_not_preflight(self):
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        first = manage.inspect(self.root)
        second = self.execute({"schema": 1, "action": "inspect"}, preflight=lambda: self.fail("inspection must not preflight"))
        self.assertEqual(first, second)
        self.assertEqual(first["state"], "absent")
        self.assertFalse(first["enabled"])
        self.assertFalse(first["has_token"])
        self.assertRegex(first["revision"], r"^[0-9a-f]{64}$")
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))
        self.assertEqual(self.commands, [])
        self.assert_private(first)

    def test_install_publishes_private_config_and_preserves_pam(self):
        result = self.install()
        self.assertEqual(result["state"], "managed")
        self.assertTrue(result["enabled"])
        self.assertTrue(result["has_token"])
        self.assertEqual(result["configuration"], self.config())
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM + manage.HOOK.encode() + b"\n")
        for name, expected in ((manage.CONFIG, 0o600), (manage.MANIFEST, 0o600), (manage.UNIT, 0o644), (manage.HELPER, 0o755)):
            self.assertEqual(stat.S_IMODE((self.root / name).stat().st_mode), expected)
        self.assertEqual(stat.S_IMODE((self.root / manage.CONFIG).parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.root / manage.STATE).stat().st_mode), 0o700)
        self.assertEqual(json.loads((self.root / manage.CONFIG).read_bytes())["token"], TOKEN)
        self.assertEqual(self.commands, [["daemon-reload"], ["enable", "--now", manage.UNIT_NAME]])
        self.assert_private(result)
        self.assert_private(self.commands)
        self.assertEqual(list((self.root / "var/lib").glob(".ssh-hub-login-transaction-*")), [])
        self.assert_failure("already_installed", self.payload("install"))

    def test_configure_blank_token_preserves_then_replaces_only_explicitly(self):
        self.install()
        old_helper = (self.root / manage.HELPER).read_bytes()
        result = self.execute(self.payload("configure", config=self.config(host_label="Changed", message_thread_id=42), token=""))
        saved = json.loads((self.root / manage.CONFIG).read_bytes())
        self.assertEqual(saved["token"], TOKEN)
        self.assertEqual(saved["host_label"], "Changed")
        self.assertEqual(saved["message_thread_id"], 42)
        self.assertEqual(result["configuration"]["host_label"], "Changed")
        self.assertEqual((self.root / manage.HELPER).read_bytes(), old_helper)
        self.assertIn(["restart", manage.UNIT_NAME], self.commands)
        result = self.execute(self.payload("configure", config=self.config(), token=NEXT_TOKEN))
        self.assertEqual(json.loads((self.root / manage.CONFIG).read_bytes())["token"], NEXT_TOKEN)
        self.assert_private(result)
        self.assert_private(self.commands)

    def test_disable_and_enable_retain_credentials_helper_and_hook(self):
        self.install()
        old_helper, old_pam = (self.root / manage.HELPER).read_bytes(), (self.root / manage.PAM).read_bytes()
        disabled = self.execute(self.payload("disable"))
        self.assertEqual(disabled["state"], "managed")
        self.assertFalse(disabled["enabled"])
        self.assertTrue(disabled["has_token"])
        self.assertEqual(json.loads((self.root / manage.CONFIG).read_bytes())["token"], TOKEN)
        self.assertEqual((self.root / manage.PAM).read_bytes(), old_pam)
        self.assertEqual((self.root / manage.HELPER).read_bytes(), old_helper)
        self.assertIn(["disable", "--now", manage.UNIT_NAME], self.commands)
        enabled = self.execute(self.payload("enable"))
        self.assertTrue(enabled["enabled"])
        self.assert_private([disabled, enabled, self.commands])

    def test_delivery_status_exposes_only_fixed_state_and_valid_timestamp(self):
        self.install()
        self.write(manage.STATE + "/status.json", json.dumps({"state": "failed", "date": TOKEN, "error": TOKEN, "token": TOKEN}))
        result = manage.inspect(self.root)
        self.assertEqual(result["state"], "managed")
        self.assertEqual(result["delivery"]["state"], "failed")
        self.assertNotIn("date", result["delivery"])
        self.assert_private(result)
        date = "2026-01-02T03:04:05.000000+00:00"
        self.write(manage.STATE + "/status.json", json.dumps({"state": "sent", "date": date, "error": TOKEN}))
        result = manage.inspect(self.root)
        self.assertEqual(result["delivery"], {"state": "sent", "date": date})
        self.assert_private(result)

    def test_remove_only_owned_files_and_recognized_queue_items(self):
        self.install()
        unrelated = self.write("etc/systemd/system/fixture.service", "retain")
        unknown = self.write(manage.STATE + "/queue/unrecognized.json", "retain")
        known = self.write(manage.STATE + "/queue/" + "a" * 32 + ".json", "{}")
        extra = self.write(str(Path(manage.CONFIG).parent / "notes.txt"), "retain")
        result = self.execute(self.payload("remove"))
        self.assertEqual(result["state"], "absent")
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
        for name in (manage.CONFIG, manage.HELPER, manage.UNIT, manage.MANIFEST):
            self.assertFalse((self.root / name).exists())
        self.assertTrue(unrelated.exists())
        self.assertTrue(unknown.exists())
        self.assertTrue(extra.exists())
        self.assertFalse(known.exists())
        self.assert_private(result)

    def test_stale_revision_blocks_every_mutation_without_overwrite(self):
        self.install()
        stale = manage.inspect(self.root)["revision"]
        with (self.root / manage.PAM).open("ab") as stream:
            stream.write(b"# administrator edit\n")
        before = self.observed()
        self.commands.clear()
        for action in ("install", "configure", "enable", "disable", "remove"):
            with self.subTest(action=action):
                self.assert_failure("revision_changed", self.payload(action, expected_revision=stale))
                self.assertEqual(self.observed(), before)
        self.assertEqual(self.commands, [])

    def test_unknown_payload_bad_hash_and_missing_token_are_refused(self):
        valid = self.payload("install")
        invalid = [("invalid_payload", dict(valid, schema=2)), ("invalid_payload", dict(valid, schema=True)),
                   ("invalid_payload", dict(valid, action="reboot")), ("invalid_payload", dict(valid, endpoint="https://example.invalid")),
                   ("invalid_payload", dict(valid, expected_revision="0")), ("invalid_payload", dict(valid, adopt_legacy="yes")),
                   ("invalid_payload", dict(valid, helper_sha256="0" * 64)),
                   ("invalid_configuration", dict(valid, config=self.config(host_label="x\nother"))),
                   ("invalid_configuration", dict(valid, config=self.config(message_thread_id=True))),
                   ("invalid_token", dict(valid, token=""))]
        for code, payload in invalid:
            with self.subTest(code=code, action=payload.get("action")):
                self.assert_failure(code, payload)
                self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
                self.assertFalse((self.root / manage.CONFIG).exists())
        self.assertEqual(self.commands, [])

    def test_foreign_or_modified_installation_is_never_overwritten_or_removed(self):
        self.install()
        with (self.root / manage.HELPER).open("ab") as stream:
            stream.write(b"# administrator edit\n")
        status = manage.inspect(self.root)
        self.assertEqual(status["state"], "foreign")
        self.assertFalse(status["has_token"])
        before = self.observed()
        self.commands.clear()
        for action in ("install", "configure", "enable", "disable", "remove"):
            with self.subTest(action=action):
                self.assert_failure("foreign_installation", self.payload(action))
                self.assertEqual(self.observed(), before)
        self.assertEqual(self.commands, [])
        self.assert_private(status)

    def legacy(self, malformed=False):
        helper = b"#!/bin/sh\n# Own known legacy fixture\nexit 0\n"
        self.write(manage.LEGACY_HELPER, helper, 0o755)
        config = "TELEGRAM_BOT_TOKEN='" + TOKEN + "'\nTELEGRAM_CHAT_ID=-1001234567890\nSSH_NOTIFY_HOST=\"Fixture host\"\nSSH_NOTIFY_TAG='#lab'\n"
        if malformed:
            config += "UNEXPECTED=$(touch /must-not-run)\n"
        self.write(manage.LEGACY_CONFIG, config)
        self.write(manage.PAM, PAM + manage.LEGACY_HOOK.encode() + b"\n", 0o644)
        patcher = mock.patch.object(manage, "KNOWN_LEGACY_SHA256", hashlib.sha256(helper).hexdigest())
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_legacy_adoption_requires_explicit_opt_in_and_preserves_secret(self):
        self.legacy()
        status = manage.inspect(self.root)
        self.assertEqual(status["state"], "legacy")
        self.assertTrue(status["has_token"])
        self.assert_private(status)
        before = self.observed()
        for action in ("install", "configure", "enable", "disable", "remove"):
            self.assert_failure("legacy_requires_adoption", self.payload(action))
            self.assertEqual(self.observed(), before)
        payload = self.payload("install", adopt_legacy=True, token="")
        payload.pop("config")
        result = self.execute(payload)
        self.assertEqual(result["state"], "managed")
        self.assertEqual(result["configuration"], self.config())
        self.assertEqual(json.loads((self.root / manage.CONFIG).read_bytes())["token"], TOKEN)
        self.assertFalse((self.root / manage.LEGACY_HELPER).exists())
        self.assertFalse((self.root / manage.LEGACY_CONFIG).exists())
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM + manage.HOOK.encode() + b"\n")
        self.assert_private(result)

    def test_legacy_unknown_config_or_hash_is_foreign(self):
        self.legacy(malformed=True)
        self.assertEqual(manage.inspect(self.root)["state"], "foreign")
        before = self.observed()
        self.assert_failure("foreign_installation", self.payload("install", adopt_legacy=True))
        self.assertEqual(before, self.observed())
        self.assertFalse((self.root / "must-not-run").exists())

    def test_service_failure_rolls_back_new_install_and_retains_unrelated_data(self):
        retained = self.write("var/lib/fixture.txt", "retain")
        def command(arguments):
            self.commands.append(arguments)
            if arguments[:1] == ["enable"]:
                raise manage.Failure("service_failed")
        self.assert_failure("service_failed", self.payload("install"), command=command)
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
        self.assertEqual(retained.read_text(), "retain")
        self.assertEqual(manage.inspect(self.root)["state"], "absent")
        for name in (manage.HELPER, manage.CONFIG, manage.UNIT, manage.MANIFEST):
            self.assertFalse((self.root / name).exists())
        self.assertEqual(list((self.root / "var/lib").glob(".ssh-hub-login-transaction-*")), [])
        self.assert_private(self.commands)

    def test_configure_failure_restores_previous_secret_configuration(self):
        self.install()
        before = self.observed()
        def command(arguments):
            self.commands.append(arguments)
            if arguments[:1] == ["restart"]:
                raise manage.Failure("service_failed")
        self.assert_failure("service_failed", self.payload("configure", config=self.config(host_label="Changed"), token=NEXT_TOKEN), command=command)
        self.assertEqual(self.observed(), before)
        self.assertTrue(manage.inspect(self.root)["enabled"])
        self.assert_private(manage.inspect(self.root))

    def test_install_does_not_overwrite_destination_appearing_during_publish(self):
        payload = self.payload("install")
        original = manage.replace
        collision = b"# Competing administrator unit, retain\n"
        injected = []
        def replace(path, data, root, mode=0o600, **keywords):
            if path == self.root / manage.UNIT and not injected:
                injected.append(True)
                self.write(manage.UNIT, collision, 0o644)
            return original(path, data, root, mode, **keywords)
        with mock.patch.object(manage, "replace", side_effect=replace):
            self.assert_failure("revision_changed", payload)
        self.assertEqual((self.root / manage.UNIT).read_bytes(), collision)
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
        self.assertFalse((self.root / manage.HELPER).exists())
        self.assertFalse((self.root / manage.CONFIG).exists())
        self.assertFalse((self.root / manage.MANIFEST).exists())
        self.assertEqual(list((self.root / "var/lib").glob(".ssh-hub-login-transaction-*")), [])

    def test_rollback_never_overwrites_a_later_administrator_configuration(self):
        self.install()
        external = dict(self.config(host_label="Administrator change"), schema=1, enabled=True, token=NEXT_TOKEN)
        raw = json.dumps(external).encode()
        def command(arguments):
            if arguments[:1] == ["restart"]:
                self.write(manage.CONFIG, raw)
                raise manage.Failure("service_failed")
        self.assert_failure("rollback_failed", self.payload("configure", config=self.config(host_label="Reviewed change")), command=command)
        self.assertEqual((self.root / manage.CONFIG).read_bytes(), raw)
        self.assertEqual(len(list((self.root / "var/lib").glob(".ssh-hub-login-transaction-*"))), 1)

    def test_legacy_adoption_failure_restores_original_hook_and_files(self):
        self.legacy()
        before = self.observed()
        def command(arguments):
            if arguments[:1] == ["enable"]:
                raise manage.Failure("service_failed")
        self.assert_failure("service_failed", self.payload("install", adopt_legacy=True, token=""), command=command)
        self.assertEqual(self.observed(), before)
        self.assertEqual(manage.inspect(self.root)["state"], "legacy")
        self.assert_private(manage.inspect(self.root))

    def test_interrupt_rolls_back_without_leaking_payload(self):
        def command(arguments):
            if arguments[:1] == ["enable"]:
                raise KeyboardInterrupt()
        self.assert_failure("interrupted", self.payload("install"), command=command)
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
        self.assertFalse((self.root / manage.CONFIG).exists())
        self.assertFalse((self.root / manage.UNIT).exists())

    def test_busy_lock_refuses_parallel_mutation(self):
        payload = self.payload("install")
        path = self.write("var/lib/ssh-hub-login-notify.lock", b"")
        with path.open("r+b") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_failure("busy", payload)
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
        self.assertFalse((self.root / manage.CONFIG).exists())

    def test_failed_rollback_keeps_only_private_recovery_preimages(self):
        self.install()
        def command(_):
            raise manage.Failure("service_failed")
        self.assert_failure("rollback_failed", self.payload("disable"), command=command)
        transactions = list((self.root / "var/lib").glob(".ssh-hub-login-transaction-*"))
        self.assertEqual(len(transactions), 1)
        self.assertEqual(stat.S_IMODE(transactions[0].stat().st_mode), 0o700)
        metadata = json.loads((transactions[0] / "transaction.json").read_bytes())
        self.assertEqual(metadata["state"], "rollback_failed")
        self.assert_private(metadata)
        for path in transactions[0].iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        for state in ("rollback_failed", "pending"):
            with self.subTest(recovery_state=state):
                metadata["state"] = state
                self.write(str((transactions[0] / "transaction.json").relative_to(self.root)), json.dumps(metadata))
                status = manage.inspect(self.root)
                expected_path = "/" + str(transactions[0].relative_to(self.root))
                self.assertIn(expected_path, status["paths"])
                self.assertTrue(status["warnings"])
                self.assert_private(status)
                before = self.observed()
                commands = []
                self.assert_failure("recovery_required", self.payload("disable"), command=commands.append)
                self.assertEqual(before, self.observed())
                self.assertEqual(commands, [])

    def test_pam_disabled_and_unsupported_preflight_never_mutate(self):
        self.write("etc/ssh/sshd_config", "UsePAM no\n", 0o644)
        self.assertTrue(manage.inspect(self.root)["warnings"])
        self.assert_failure("pam_disabled", self.payload("install"))
        self.assertEqual((self.root / manage.PAM).read_bytes(), PAM)
        self.write("etc/ssh/sshd_config", "UsePAM yes\n", 0o644)
        def preflight():
            raise manage.Failure("unsupported")
        self.assert_failure("unsupported", self.payload("install"), preflight=preflight)
        self.assertFalse((self.root / "var/lib/ssh-hub-login-notify.lock").exists())
        self.assertEqual(self.commands, [])

    def test_symlink_fifo_and_world_writable_paths_are_refused(self):
        config = self.write("outside.json", "{}")
        (self.root / manage.CONFIG).parent.mkdir(mode=0o700)
        (self.root / manage.CONFIG).symlink_to(config)
        with self.assertRaises(manage.Failure) as caught:
            manage.inspect(self.root)
        self.assertEqual(caught.exception.code, "unsafe_path")
        (self.root / manage.CONFIG).unlink()
        os.mkfifo(self.root / manage.CONFIG, 0o600)
        with self.assertRaises(manage.Failure):
            manage.inspect(self.root)
        (self.root / manage.CONFIG).unlink()
        (self.root / "usr/local/lib").chmod(0o777)
        with self.assertRaises(manage.Failure):
            manage.inspect(self.root)
        self.assertEqual(config.read_text(), "{}")
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
