#!/usr/bin/env python3
"""Tests only private directories and fake systemd; never installs a host service."""
import base64
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest import mock
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("monitor_install", HERE / "install.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Tests(unittest.TestCase):
    def payload(self):
        source = (HERE / "collector.py").read_bytes()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        return {"instance_id": str(uuid.uuid4()), "port": port, "token": "a" * 64, "collector": base64.b64encode(source).decode(), "collector_sha256": hashlib.sha256(source).hexdigest(), "config": {"listen": "127.0.0.1", "port": port, "targets": [{"id": "fixture", "name": "Fixture", "kind": "tcp", "host": "127.0.0.1", "port": 9}]}}

    def root(self, folder):
        root = Path(folder)
        for part in ["opt", "etc", "var/lib", "etc/systemd/system"]:
            (root / part).mkdir(parents=True, exist_ok=True)
        return root

    def test_success_private_credentials_and_exclusive_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            root, payload, commands = self.root(folder), self.payload(), []
            old = os.umask(0o077)
            try:
                real_link = os.link
                def same_mount_link(source, destination):
                    if Path(source).parent != Path(destination).parent:
                        raise OSError(errno.EXDEV, "Synthetic separate /opt mount")
                    return real_link(source, destination)
                with mock.patch.object(module.os, "link", side_effect=same_mount_link):
                    result = module.install(payload, root=root, command=commands.append, check=lambda: None, health_check=lambda *_: True)
            finally:
                os.umask(old)
            name = "ssh-hub-monitor-" + payload["instance_id"]
            token = root / "etc" / name / "token"
            self.assertTrue(result["ok"])
            self.assertEqual(token.stat().st_mode & 0o777, 0o600)
            self.assertEqual((root / "opt" / name).stat().st_mode & 0o777, 0o755)
            self.assertEqual((root / "opt" / name / "collector.py").stat().st_mode & 0o777, 0o644)
            unit = (root / "etc/systemd/system" / (name + ".service")).read_text()
            self.assertIn("DynamicUser=yes", unit)
            self.assertIn("LoadCredential=api-token:", unit)
            self.assertEqual(list((root / "etc/systemd/system").iterdir()), [root / "etc/systemd/system" / (name + ".service")])
            self.assertNotIn(payload["token"], unit + json.dumps(result) + json.dumps(commands))
            with self.assertRaisesRegex(module.InstallationFailure, "already_exists"):
                module.install(payload, root=root, command=commands.append, check=lambda: None, health_check=lambda *_: True)
            self.assertEqual(token.read_text(), payload["token"])

    def test_start_failure_rolls_back_only_new_install(self):
        with tempfile.TemporaryDirectory() as folder:
            root, payload, commands = self.root(folder), self.payload(), []
            retained = root / "opt" / "existing"; retained.write_text("keep")
            def command(arguments):
                commands.append(arguments)
                if arguments[:1] == ["enable"]:
                    raise module.InstallationFailure("systemd_failed")
            with self.assertRaises(module.InstallationFailure):
                module.install(payload, root=root, command=command, check=lambda: None, health_check=lambda *_: True)
            name = "ssh-hub-monitor-" + payload["instance_id"]
            self.assertFalse((root / "opt" / name).exists())
            self.assertFalse((root / "etc" / name).exists())
            self.assertFalse((root / "etc/systemd/system" / (name + ".service")).exists())
            self.assertEqual(list((root / "etc/systemd/system").iterdir()), [])
            self.assertEqual(retained.read_text(), "keep")
            self.assertIn(["disable", "--now", name + ".service"], commands)
            self.assertIn(["clean", "--what=state", name + ".service"], commands)

    def test_bad_config_secret_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root, payload = self.root(folder), self.payload()
            invalid = dict(payload, token="not-valid")
            with self.assertRaises(module.InstallationFailure):
                module.install(invalid, root=root, command=lambda *_: None, check=lambda: None)
            invalid = dict(payload, collector_sha256="0" * 64)
            with self.assertRaises(module.InstallationFailure):
                module.install(invalid, root=root, command=lambda *_: None, check=lambda: None)
            invalid = dict(payload, config={"listen": "0.0.0.0", "port": payload["port"]})
            with self.assertRaises(module.InstallationFailure):
                module.install(invalid, root=root, command=lambda *_: None, check=lambda: None)
            name = "ssh-hub-monitor-" + payload["instance_id"]
            (root / "opt" / name).symlink_to("/synthetic-missing")
            with self.assertRaisesRegex(module.InstallationFailure, "already_exists"):
                module.install(payload, root=root, command=lambda *_: None, check=lambda: None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
