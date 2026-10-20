#!/usr/bin/env python3
"""A nonblocking PAM event sender and independent Telegram delivery service."""
import sys
sys.dont_write_bytecode = True
import contextlib
import datetime
import http.client
import json
import itertools
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import stat
import struct
import subprocess
import time
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

CONFIG = "etc/ssh-hub-login-notify/config.json"
STATE = "var/lib/ssh-hub-login-notify"
SOCKET = "run/ssh-hub-login-notify/events.sock"
MAX_EVENT = 4096
MAX_QUEUE = 128


MESSAGE_VARIABLES = {"server", "user", "ip", "time", "timezone", "terminal", "service", "tag"}
DEFAULT_TEMPLATE = "SSH-сессия открыта\nСервер: {server}\nПользователь: {user}\nИсточник: {ip}\nВремя: {time} ({timezone})\nТерминал: {terminal}\n{tag}"


def validate_message_settings(value, check_timezone=True):
    zone = value.get("time_zone")
    if "time_zone" in value:
        if (not isinstance(zone, str) or len(zone.encode()) > 100 or not zone
                or not re.fullmatch(r"[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*", zone)
                or any(part in (".", "..") for part in zone.split("/"))):
            raise ValueError("invalid_configuration")
        if check_timezone:
            try:
                ZoneInfo(zone)
            except (ValueError, ZoneInfoNotFoundError):
                raise ValueError("timezone_unavailable")
    template = value.get("message_template")
    if "message_template" in value:
        if (not isinstance(template, str) or not template.strip() or len(template.encode()) > 2048
                or any((ord(c) < 32 and c != "\n") or ord(c) == 127 for c in template)):
            raise ValueError("invalid_configuration")
        remainder = re.sub(r"\{([a-z_]+)\}", lambda m: "" if m[1] in MESSAGE_VARIABLES else m[0], template)
        if "{" in remainder or "}" in remainder:
            raise ValueError("invalid_configuration")


def plain(value, maximum, empty=False):
    if not isinstance(value, str) or len(value.encode("utf-8")) > maximum or (not empty and not value) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid_configuration")
    return value


def validate_config(value, require_token=True):
    if not isinstance(value, dict) or set(value) - {"schema", "enabled", "token", "chat_id", "host_label", "tag", "message_thread_id", "time_zone", "message_template"}:
        raise ValueError("invalid_configuration")
    chat = plain(value.get("chat_id"), 64)
    if not re.fullmatch(r"-?[1-9][0-9]{0,18}|@[A-Za-z][A-Za-z0-9_]{4,31}", chat):
        raise ValueError("invalid_configuration")
    plain(value.get("host_label"), 200)
    tag = plain(value.get("tag", ""), 80, empty=True)
    if tag and not re.fullmatch(r"[\w-]{1,80}", tag, re.UNICODE):
        raise ValueError("invalid_configuration")
    thread = value.get("message_thread_id")
    if thread is not None and (type(thread) is not int or not 1 <= thread <= 2147483647):
        raise ValueError("invalid_configuration")
    token = value.get("token", "")
    if require_token and (not isinstance(token, str) or not re.fullmatch(r"[0-9]{4,20}:[A-Za-z0-9_-]{20,200}", token)):
        raise ValueError("invalid_token")
    if require_token and any(token in (value.get(key) or "") for key in ("chat_id", "host_label", "tag", "message_template")):
        raise ValueError("invalid_configuration")
    if "schema" in value and (type(value["schema"]) is not int or value["schema"] != 1) or "enabled" in value and type(value["enabled"]) is not bool:
        raise ValueError("invalid_configuration")
    validate_message_settings(value)
    return value


def safe_read(path, maximum, secret=False):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & (0o077 if secret else 0o022) or info.st_size > maximum:
        raise ValueError("unsafe_file")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if before.st_ino != info.st_ino or before.st_dev != info.st_dev:
            raise ValueError("changed_file")
        data = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
        if len(data) > maximum or (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise ValueError("changed_file")
        return data


def atomic_json(path, value):
    temporary = path.parent / ("." + path.name + "." + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode())
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(OSError):
            temporary.unlink()


def event(value):
    if not isinstance(value, dict) or value.get("service") != "sshd" or value.get("type") != "open_session":
        raise ValueError("invalid_event")
    for key in ("user", "remote_host", "tty"):
        plain(value.get(key, ""), 512, empty=True)
    if type(value.get("time")) not in (int, float) or not 0 < value["time"] <= time.time() + 300:
        raise ValueError("invalid_event")
    return {key: value.get(key, "") for key in ("service", "type", "user", "remote_host", "tty", "time")}


def enqueue(root=Path("/"), environment=None):
    # No configuration, DNS, file queue, shell, or HTTPS operation runs in PAM.
    # A missing/full socket drops an event rather than delaying server login.
    try:
        environment = os.environ if environment is None else environment
        if environment.get("PAM_TYPE") != "open_session" or environment.get("PAM_SERVICE") != "sshd":
            return 0
        def clipped(key):
            return "".join(c for c in str(environment.get(key, "")) if ord(c) >= 32 and ord(c) != 127)[:128]
        value = {"service": "sshd", "type": "open_session", "user": clipped("PAM_USER"), "remote_host": clipped("PAM_RHOST"), "tty": clipped("PAM_TTY"), "time": time.time()}
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        if len(data) > MAX_EVENT:
            return 0
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
            channel.setblocking(False)
            channel.sendto(data, str(root / SOCKET))
    except BaseException:
        pass
    return 0


def telegram_transport(token, body):
    # http.client does not inherit environment/system proxy settings or follow
    # redirects. The token exists only in this TLS request path, never argv.
    connection = http.client.HTTPSConnection("api.telegram.org", timeout=3, context=ssl.create_default_context())
    try:
        connection.request("POST", "/bot" + token + "/sendMessage", body=body, headers={"Content-Type": "application/json", "Accept": "application/json"})
        response = connection.getresponse()
        return response.status, response.read(65537)
    finally:
        connection.close()


def render_message(config, value):
    zone_name = config.get("time_zone") or "UTC"
    local = datetime.datetime.fromtimestamp(value["time"], ZoneInfo(zone_name))
    values = {"server": config["host_label"], "user": value["user"] or "—", "ip": value["remote_host"] or "локально / не указан",
              "time": local.strftime("%Y-%m-%d %H:%M:%S %z"), "timezone": zone_name,
              "terminal": value["tty"] or "—", "service": value["service"], "tag": "#" + config["tag"] if config.get("tag") else ""}
    template = config.get("message_template")
    if template is None and "time_zone" not in config:
        # Existing installations keep their previous format until explicitly configured.
        values["time"] = local.strftime("%Y-%m-%d %H:%M:%S UTC")
        template = "SSH-сессия открыта\nСервер: {server}\nПользователь: {user}\nИсточник: {ip}\nВремя: {time}" + ("\nТерминал: {terminal}" if value["tty"] else "") + "\n{tag}"
    return re.sub(r"\{([a-z_]+)\}", lambda m: values[m[1]], template if template is not None else DEFAULT_TEMPLATE).rstrip("\n")


def deliver(config, value, transport=None):
    try:
        validate_config(config)
        if config.get("enabled") is False:
            return {"state": "failed", "error": "disabled"}
        value = event(value)
        text = render_message(config, value)
        body = {"chat_id": config["chat_id"], "text": text[:3500], "link_preview_options": {"is_disabled": True}}
        if config.get("message_thread_id") is not None:
            body["message_thread_id"] = config["message_thread_id"]
        code, data = (transport or telegram_transport)(config["token"], json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode())
        if not isinstance(data, bytes) or len(data) > 65536:
            return {"state": "failed", "error": "invalid_response"}
        try:
            response = json.loads(data)
        except (ValueError, UnicodeError):
            return {"state": "failed", "error": "invalid_response"}
        if not isinstance(response, dict):
            return {"state": "failed", "error": "invalid_response"}
        if code == 200 and response.get("ok") is True:
            return {"state": "sent"}
        if code == 429:
            retry = response.get("parameters", {}).get("retry_after", 60) if isinstance(response.get("parameters", {}), dict) else 60
            return {"state": "retry", "error": "rate_limited", "retry_after": min(3600, max(1, retry if type(retry) is int else 60))}
        if code >= 500:
            return {"state": "retry", "error": "unavailable", "retry_after": 30}
        return {"state": "failed", "error": "unauthorized" if code == 401 else "forbidden" if code == 403 else "redirect" if 300 <= code < 400 else "rejected"}
    except BaseException:
        return {"state": "retry", "error": "transport", "retry_after": 30}


class Worker:
    def __init__(self, root=Path("/")):
        self.root = root
        self.directory = root / STATE
        self.queue = self.directory / "queue"
        self.stopping = False
        self.child = None

    def stop(self, *_):
        self.stopping = True
        if self.child is not None:
            with contextlib.suppress(OSError):
                self.child.kill()

    def result(self, value):
        atomic_json(self.directory / "status.json", {"state": value["state"], "date": datetime.datetime.now(datetime.timezone.utc).isoformat()})

    def send(self, value):
        # A separate child imposes a hard total deadline even on DNS resolution.
        self.child = subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()), "--deliver"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, close_fds=True)
        try:
            output, _ = self.child.communicate(json.dumps(value).encode(), timeout=8)
            if len(output) <= 4096:
                result = json.loads(output)
                if result.get("state") in ("sent", "failed", "retry"):
                    return result
        except (ValueError, OSError, subprocess.SubprocessError):
            self.child.kill(); self.child.communicate()
        finally:
            self.child = None
        return {"state": "retry", "error": "timeout", "retry_after": 30}

    def run(self):
        endpoint = self.root / SOCKET
        self.queue.mkdir(mode=0o700, exist_ok=True)
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
            channel.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
            channel.bind(str(endpoint)); os.chmod(endpoint, 0o600); channel.settimeout(.2)
            next_send = 0
            try:
                self.result({"state": "ready"})
                while not self.stopping:
                    config = validate_config(json.loads(safe_read(self.root / CONFIG, 16384, secret=True)))
                    if not config.get("enabled"):
                        return
                    try:
                        data, credentials, flags, _ = channel.recvmsg(MAX_EVENT + 1, socket.CMSG_SPACE(struct.calcsize("3i")))
                        trusted = any(level == socket.SOL_SOCKET and kind == socket.SCM_CREDENTIALS and struct.unpack("3i", value[:12])[1] == 0 for level, kind, value in credentials if len(value) >= 12)
                        if trusted and not flags & socket.MSG_TRUNC and len(data) <= MAX_EVENT:
                            value = event(json.loads(data))
                            if len(list(itertools.islice(self.queue.iterdir(), MAX_QUEUE))) < MAX_QUEUE:
                                atomic_json(self.queue / (uuid.uuid4().hex + ".json"), {"event": value, "attempts": 0, "next": 0})
                    except (socket.timeout, BlockingIOError):
                        pass
                    except (ValueError, UnicodeError):
                        pass
                    now = time.time()
                    if now < next_send:
                        continue
                    pending = sorted(itertools.islice(self.queue.iterdir(), MAX_QUEUE))
                    for path in pending:
                        try:
                            item = json.loads(safe_read(path, MAX_EVENT + 1024, secret=True)); value = event(item["event"])
                            if now - value["time"] > 3600 or item["attempts"] >= 3:
                                path.unlink(); continue
                            if item["next"] > now:
                                continue
                            result = self.send(value); self.result(result)
                            delay = max(3.1, min(3600, result.get("retry_after", 30))) if result["state"] == "retry" else 3.1
                            next_send = time.time() + delay
                            if result["state"] == "retry" and item["attempts"] < 2:
                                item["attempts"] += 1; item["next"] = time.time() + min(3600, max(3.1, result.get("retry_after", 30))); atomic_json(path, item)
                            else:
                                path.unlink()
                            break
                        except (ValueError, KeyError, TypeError, OSError):
                            # Never follow queue links or display their contents.
                            with contextlib.suppress(OSError):
                                path.unlink()
            finally:
                with contextlib.suppress(OSError):
                    endpoint.unlink()


def main():
    os.umask(0o077)
    if sys.argv[1:] == ["--enqueue"]:
        return enqueue()
    if sys.argv[1:] == ["--deliver"]:
        try:
            data = sys.stdin.buffer.read(MAX_EVENT + 1)
            if len(data) > MAX_EVENT:
                raise ValueError()
            result = deliver(json.loads(safe_read(Path("/") / CONFIG, 16384, secret=True)), json.loads(data))
        except BaseException:
            result = {"state": "failed", "error": "configuration"}
        print(json.dumps(result, separators=(",", ":")))
        return 0
    if sys.argv[1:] == ["--worker"] and sys.platform.startswith("linux") and os.geteuid() == 0:
        worker = Worker()
        for name in (signal.SIGTERM, signal.SIGINT):
            signal.signal(name, worker.stop)
        try:
            worker.run(); return 0
        except BaseException:
            return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
