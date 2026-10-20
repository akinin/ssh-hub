#!/usr/bin/env python3
"""Synthetic notification tests; no system PAM, Telegram or external network."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import time
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("login_notify_fixture", HERE / "notify.py")
notify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notify)
TOKEN = "123456789:" + "a" * 35


def configuration(**updates):
    result = {"schema": 1, "enabled": True, "chat_id": "-1001234567890",
              "host_label": "Fixture host", "tag": "lab", "token": TOKEN}
    result.update(updates)
    return result


def event(**updates):
    result = {"service": "sshd", "type": "open_session", "user": "fixture",
              "remote_host": "192.0.2.14", "tty": "pts/4", "time": time.time()}
    result.update(updates)
    return result


class NotificationTests(unittest.TestCase):
    def deliver(self, response=(200, b'{"ok":true,"result":{"message_id":1}}'), config=None, material=None):
        calls = []
        def transport(token, body):
            calls.append((token, body))
            return response
        result = notify.deliver(config or configuration(), material or event(), transport=transport)
        return result, calls

    def assert_private(self, value):
        encoded = json.dumps(value, ensure_ascii=False)
        self.assertNotIn(TOKEN, encoded)
        self.assertNotIn("api.telegram.org/bot", encoded)

    def test_valid_configuration_and_optional_thread(self):
        original = configuration(message_thread_id=42)
        parsed = notify.validate_config(original)
        self.assertEqual(parsed["chat_id"], original["chat_id"])
        self.assertEqual(parsed["message_thread_id"], 42)
        self.assertEqual(parsed["token"], TOKEN)
        without_token = configuration(token="")
        self.assertEqual(notify.validate_config(without_token, require_token=False)["chat_id"], without_token["chat_id"])
        with self.assertRaises(ValueError):
            notify.validate_config(without_token)

    def test_config_validation_rejects_untrusted_fields_types_and_bounds(self):
        samples = [
            configuration(schema=2), configuration(schema=True), configuration(enabled="true"),
            configuration(token="wrong"), configuration(token=TOKEN + "\n"),
            configuration(chat_id="not-a-chat"), configuration(chat_id="1\n2"),
            configuration(host_label="x" * 4096), configuration(host_label="host\x00name"),
            configuration(tag="x" * 4096), configuration(message_thread_id=True),
            configuration(message_thread_id=-1), configuration(message_thread_id=2**64),
            configuration(endpoint="https://untrusted.example/bot"),
        ]
        for sample in samples:
            with self.subTest(fields=[key for key in sample if (type(sample[key]), sample[key]) != (type(configuration().get(key)), configuration().get(key))]):
                with self.assertRaises(ValueError):
                    notify.validate_config(sample)

    def test_delivery_body_has_only_expected_message_material(self):
        result, calls = self.deliver(config=configuration(message_thread_id=42))
        self.assertEqual(result["state"], "sent")
        self.assertEqual(len(calls), 1)
        token, raw = calls[0]
        self.assertEqual(token, TOKEN)
        self.assertIsInstance(raw, bytes)
        body = json.loads(raw)
        self.assertEqual(body["chat_id"], "-1001234567890")
        self.assertEqual(body["message_thread_id"], 42)
        self.assertIn("fixture", body["text"])
        self.assertIn("192.0.2.14", body["text"])
        self.assertNotIn(TOKEN, raw.decode())
        self.assertLess(len(raw), 16384)
        self.assert_private(result)

    def test_redirects_are_not_success_and_are_not_retried(self):
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code):
                result, calls = self.deliver((code, b'{"ok":true}'))
                self.assertEqual(result["state"], "failed")
                self.assertEqual(len(calls), 1)
                self.assert_private(result)

    def test_server_errors_retry_and_rate_limit_is_bounded(self):
        for code in (500, 502, 503):
            with self.subTest(code=code):
                result, calls = self.deliver((code, b'{"ok":false}'))
                self.assertEqual(result["state"], "retry")
                self.assertEqual(len(calls), 1)
                self.assert_private(result)
        for value in (1, 999999999):
            result, _ = self.deliver((429, json.dumps({"ok": False, "parameters": {"retry_after": value}}).encode()))
            self.assertEqual(result["state"], "retry")
            if "retry_after" in result:
                self.assertGreaterEqual(result["retry_after"], 1)
                self.assertLessEqual(result["retry_after"], 3600)
            self.assert_private(result)

    def test_bad_response_is_fixed_error_without_remote_details(self):
        secret_error = ("remote secret " + TOKEN).encode()
        cases = [(400, secret_error), (401, secret_error), (403, secret_error),
                 (200, b"invalid json"), (200, b"[]"),
                 (200, json.dumps({"ok": False, "description": secret_error.decode()}).encode()),
                 (200, b'{"ok":"true"}'), (200, b"x" * 100000)]
        for response in cases:
            with self.subTest(code=response[0], size=len(response[1])):
                result, calls = self.deliver(response)
                self.assertEqual(result["state"], "failed")
                self.assertEqual(len(calls), 1)
                self.assert_private(result)
                self.assertNotIn("remote secret", json.dumps(result))

    def test_transport_error_is_private_and_retryable(self):
        def transport(*_):
            raise OSError("https://api.telegram.org/bot" + TOKEN + "/sendMessage failed")
        result = notify.deliver(configuration(), event(), transport=transport)
        self.assertEqual(result["state"], "retry")
        self.assert_private(result)

    def test_event_fields_are_bounded_and_unknown_environment_is_ignored(self):
        for changes in ({"service": "sudo"}, {"type": "close_session"},
                        {"user": "x" * 513}, {"tty": "x\x00"},
                        {"remote_host": "x\nignored"}, {"time": float("nan")},
                        {"time": float("inf")}, {"time": time.time() + 600}):
            with self.subTest(fields=list(changes)):
                with self.assertRaises(ValueError):
                    notify.event(event(**changes))
        parsed = notify.event(event(untrusted=TOKEN))
        self.assertNotIn("untrusted", parsed)
        self.assertNotIn(TOKEN, json.dumps(parsed))

    def test_production_transport_uses_only_fixed_verified_tls_without_redirects(self):
        captured = {}
        class Response:
            status = 302
            def read(self, limit):
                captured["read_limit"] = limit
                return b'{"ok":true}'
        class Connection:
            def __init__(self, host, timeout, context):
                captured.update(host=host, timeout=timeout, context=context)
            def request(self, method, path, body, headers):
                captured.update(method=method, path=path, body=body, headers=headers)
            def getresponse(self):
                return Response()
            def close(self):
                captured["closed"] = True
        with mock.patch.object(notify.http.client, "HTTPSConnection", Connection):
            self.assertEqual(notify.telegram_transport(TOKEN, b"{}"), (302, b'{"ok":true}'))
        self.assertEqual(captured["host"], "api.telegram.org")
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["path"], "/bot" + TOKEN + "/sendMessage")
        self.assertEqual(captured["context"].verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(captured["context"].check_hostname)
        self.assertLessEqual(captured["timeout"], 5)
        self.assertEqual(captured["read_limit"], 65537)
        self.assertTrue(captured["closed"])

    def test_private_safe_read_never_follows_links_or_special_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / "private.json"
            config.write_text("private")
            config.chmod(0o600)
            self.assertEqual(notify.safe_read(config, 16, secret=True), b"private")
            config.chmod(0o644)
            with self.assertRaises(ValueError):
                notify.safe_read(config, 16, secret=True)
            config.chmod(0o600)
            link = root / "link.json"
            link.symlink_to(config)
            with self.assertRaises(ValueError):
                notify.safe_read(link, 16, secret=True)
            with self.assertRaises(ValueError):
                notify.safe_read(config, 2, secret=True)
            fifo = root / "pipe"
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(ValueError):
                notify.safe_read(fifo, 16, secret=True)

    def test_enqueue_is_authentication_safe_without_worker(self):
        environment = {"PAM_SERVICE": "sshd", "PAM_TYPE": "open_session",
                       "PAM_USER": "fixture", "PAM_RHOST": "192.0.2.14", "PAM_TTY": "ssh",
                       "SYNTHETIC_SECRET": TOKEN}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with mock.patch.object(notify, "deliver", side_effect=AssertionError("PAM must never send Telegram")):
                started = time.monotonic()
                self.assertEqual(notify.enqueue(root=root, environment=environment), 0)
                self.assertLess(time.monotonic() - started, 1)
                for invalid in ({}, dict(environment, PAM_TYPE="close_session"), dict(environment, PAM_SERVICE="sudo")):
                    self.assertEqual(notify.enqueue(root=root, environment=invalid), 0)
            for path in root.rglob("*"):
                if path.is_file():
                    self.assertNotIn(TOKEN, path.read_text(errors="replace"))

    def test_enqueue_sends_only_sanitized_pam_fields_to_nonblocking_unix_socket(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            channel = mock.MagicMock()
            channel.__enter__.return_value = channel
            with mock.patch.object(notify.socket, "socket", return_value=channel) as create:
                env = {"PAM_SERVICE": "sshd", "PAM_TYPE": "open_session", "PAM_USER": "fi\nxture",
                       "PAM_RHOST": "192.0.2.15", "PAM_TTY": "t" * 5000, "TOKEN": TOKEN}
                self.assertEqual(notify.enqueue(root=root, environment=env), 0)
            create.assert_called_once_with(socket.AF_UNIX, socket.SOCK_DGRAM)
            channel.setblocking.assert_called_once_with(False)
            raw, target = channel.sendto.call_args.args
            self.assertEqual(target, str(root / notify.SOCKET))
            value = json.loads(raw)
            self.assertEqual(value["user"], "fixture")
            self.assertLessEqual(len(value["tty"]), 128)
            self.assertLessEqual(len(raw), notify.MAX_EVENT)
            self.assertNotIn(TOKEN, raw.decode())
            self.assertEqual(set(value), {"service", "type", "user", "remote_host", "tty", "time"})

    def test_worker_kills_and_drains_only_its_timed_out_delivery_child(self):
        class Child:
            def __init__(self):
                self.killed = False
                self.calls = 0
            def communicate(self, material=None, timeout=None):
                self.calls += 1
                if self.calls == 1:
                    raise subprocess.TimeoutExpired("synthetic delivery", timeout)
                return b"", None
            def kill(self):
                self.killed = True
        child = Child()
        with tempfile.TemporaryDirectory() as folder:
            worker = notify.Worker(Path(folder))
            with mock.patch.object(notify.subprocess, "Popen", return_value=child) as create:
                result = worker.send(event())
            self.assertTrue(child.killed)
            self.assertEqual(child.calls, 2)
            self.assertIsNone(worker.child)
            self.assertEqual(result["state"], "retry")
            self.assert_private(result)
            self.assertNotIn(TOKEN, repr(create.call_args))

    def test_worker_accepts_only_root_credentials_and_cleans_its_socket(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for directory in ((root / notify.CONFIG).parent, root / notify.STATE, (root / notify.SOCKET).parent):
                directory.mkdir(parents=True, exist_ok=True)
                directory.chmod(0o700)
            config = root / notify.CONFIG
            config.write_text(json.dumps(configuration()))
            config.chmod(0o600)
            worker = notify.Worker(root)
            delivered = []
            payloads = [(json.dumps(event(user="trusted")).encode(), 0),
                        (json.dumps(event(user="untrusted")).encode(), 501),
                        (json.dumps(event(service="sudo")).encode(), 0)]
            class Channel:
                def __enter__(self):
                    return self
                def __exit__(self, *_):
                    return False
                def setsockopt(self, *_):
                    pass
                def bind(self, path):
                    Path(path).touch(mode=0o600)
                def settimeout(self, *_):
                    pass
                def recvmsg(self, *_):
                    if not payloads:
                        worker.stopping = True
                        raise socket.timeout()
                    data, uid = payloads.pop(0)
                    return data, [(socket.SOL_SOCKET, 999, struct.pack("3i", 123, uid, uid))], 0, None
            def send(value):
                delivered.append(value)
                return {"state": "sent"}
            with mock.patch.object(notify.socket, "SO_PASSCRED", 998, create=True), \
                 mock.patch.object(notify.socket, "SCM_CREDENTIALS", 999, create=True), \
                 mock.patch.object(notify.socket, "socket", return_value=Channel()), \
                 mock.patch.object(worker, "send", side_effect=send):
                worker.run()
            self.assertEqual([value["user"] for value in delivered], ["trusted"])
            self.assertFalse((root / notify.SOCKET).exists())
            self.assertEqual(list(worker.queue.iterdir()), [])
            self.assert_private(json.loads((root / notify.STATE / "status.json").read_bytes()))

    def test_template_timezone_and_literal_custom_fields(self):
        material = event(time=1735732800)  # 2025-01-01 12:00:00 UTC
        cfg = configuration(time_zone="Asia/Tbilisi", message_template="Вход: {server}\nКто: {user}\nАдрес: {ip}\n{time} · {timezone}\n{terminal} / {service}\n{tag}\n#PVE_Olshaniki")
        result, calls = self.deliver(config=cfg, material=material)
        self.assertEqual(result["state"], "sent")
        text = json.loads(calls[0][1])["text"]
        self.assertIn("2025-01-01 16:00:00 +0400 · Asia/Tbilisi", text)
        self.assertIn("#PVE_Olshaniki", text)
        self.assertIn("Кто: fixture", text)
        self.assertIn("Адрес: 192.0.2.14", text)
        self.assertIn("pts/4 / sshd", text)
        self.assertNotIn("{user}", text)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("parse_mode", json.loads(calls[0][1]))
        literal = notify.render_message(cfg, event(user="{server}"))
        self.assertIn("Кто: {server}", literal)  # no recursive expansion or evaluation

    def test_timezones_dst_legacy_and_optional_fields(self):
        winter = event(time=1735732800)
        summer = event(time=1751371200)  # 2025-07-01 12:00:00 UTC
        cfg = configuration(time_zone="America/New_York", message_template="{time} {timezone}")
        self.assertIn("07:00:00 -0500", notify.render_message(cfg, winter))
        self.assertIn("08:00:00 -0400", notify.render_message(cfg, summer))
        legacy = notify.render_message(configuration(tag=""), event(time=1735732800, tty=""))
        self.assertIn("2025-01-01 12:00:00 UTC", legacy)
        self.assertNotIn("Терминал", legacy)
        self.assertFalse(legacy.endswith("\n"))
        self.assertIn("(Asia/Tbilisi)", notify.render_message(configuration(time_zone="Asia/Tbilisi"), winter))

    def test_template_validation_and_no_secret_transport(self):
        for fields in ({"time_zone": "NoSuch/Fixture"}, {"time_zone": "../UTC"}, {"time_zone": None},
                       {"message_template": "{token}"}, {"message_template": "{user.__class__}"},
                       {"message_template": "{user!r}"}, {"message_template": "{ip"},
                       {"message_template": ""}, {"message_template": None},
                       {"message_template": "x\r"}, {"message_template": "Ж" * 1025},
                       {"message_template": TOKEN}):
            with self.subTest(fields=tuple(fields)):
                with self.assertRaises(ValueError):
                    notify.validate_config(configuration(**fields))
                _, calls = self.deliver(config=configuration(**fields))
                self.assertEqual(calls, [])
        notify.validate_config(configuration(message_template="Ж" * 1024))



if __name__ == "__main__":
    unittest.main(verbosity=2)
