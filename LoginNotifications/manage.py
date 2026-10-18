#!/usr/bin/env python3
"""Reviewed root-only manager; the bounded JSON protocol never exports secrets."""
import sys
sys.dont_write_bytecode = True
import ast
import base64
import contextlib
import datetime
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import uuid

KNOWN_LEGACY_SHA256 = "3c9e1bf86cd1ef43a58326994581e3f1e71be7925290c703cd668207ae4084b3"
LEGACY_HOOK = "session optional pam_exec.so quiet /usr/local/sbin/ssh-login-telegram"
HOOK = "session [default=ignore] pam_exec.so quiet quiet_log type=open_session /usr/bin/python3 -I /usr/local/lib/ssh-hub-login-notify/notify.py --enqueue"
PAM = "etc/pam.d/sshd"
HELPER = "usr/local/lib/ssh-hub-login-notify/notify.py"
CONFIG = "etc/ssh-hub-login-notify/config.json"
STATE = "var/lib/ssh-hub-login-notify"
MANIFEST = STATE + "/manifest.json"
UNIT = "etc/systemd/system/ssh-hub-login-notify.service"
LEGACY_HELPER = "usr/local/sbin/ssh-login-telegram"
LEGACY_CONFIG = "etc/ssh-login-telegram.conf"
UNIT_NAME = "ssh-hub-login-notify.service"
OBSERVED = (PAM, HELPER, CONFIG, MANIFEST, UNIT, LEGACY_HELPER, LEGACY_CONFIG)
EMPTY_CONFIG = {"chat_id": "", "host_label": "", "tag": ""}
UNIT_TEXT = """[Unit]
Description=SSH Hub Telegram SSH session notifications
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -I /usr/local/lib/ssh-hub-login-notify/notify.py --worker
User=root
Group=root
RuntimeDirectory=ssh-hub-login-notify
RuntimeDirectoryMode=0700
StateDirectory=ssh-hub-login-notify
StateDirectoryMode=0700
UMask=0077
Restart=on-failure
RestartSec=5
TimeoutStopSec=12
KillMode=control-group
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/lib/ssh-hub-login-notify /run/ssh-hub-login-notify
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
"""


class Failure(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def owner(root):
    return 0 if root == Path("/") else os.geteuid()


def safe_parents(path, root):
    current = path.parent
    while current != root and current != current.parent:
        if os.path.lexists(current):
            info = current.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner(root) or info.st_mode & 0o022:
                raise Failure("unsafe_path")
        current = current.parent


def read(path, root, maximum=262144, secret=False):
    safe_parents(path, root)
    if not os.path.lexists(path):
        return None
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != owner(root) or info.st_mode & (0o077 if secret else 0o022) or info.st_size > maximum:
        raise Failure("unsafe_path")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if (before.st_ino, before.st_dev) != (info.st_ino, info.st_dev):
            raise Failure("revision_changed")
        data = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
        if len(data) > maximum or (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise Failure("revision_changed")
        return data


def configuration(value, require_token=False):
    if not isinstance(value, dict) or set(value) - {"schema", "enabled", "token", "chat_id", "host_label", "tag", "message_thread_id"}:
        raise Failure("invalid_configuration")
    for key, maximum, empty in (("chat_id", 64, False), ("host_label", 200, False), ("tag", 80, True)):
        text = value.get(key, "" if empty else None)
        if not isinstance(text, str) or len(text.encode()) > maximum or (not text and not empty) or any(ord(c) < 32 or ord(c) == 127 for c in text):
            raise Failure("invalid_configuration")
    if not re.fullmatch(r"-?[1-9][0-9]{0,18}|@[A-Za-z][A-Za-z0-9_]{4,31}", value["chat_id"]):
        raise Failure("invalid_configuration")
    if value.get("tag") and not re.fullmatch(r"[\w-]{1,80}", value["tag"], re.UNICODE):
        raise Failure("invalid_configuration")
    thread = value.get("message_thread_id")
    if thread is not None and (type(thread) is not int or not 1 <= thread <= 2147483647):
        raise Failure("invalid_configuration")
    if require_token and (not isinstance(value.get("token"), str) or not re.fullmatch(r"[0-9]{4,20}:[A-Za-z0-9_-]{20,200}", value["token"])):
        raise Failure("invalid_token")
    if require_token and any(value["token"] in value.get(key, "") for key in ("chat_id", "host_label", "tag")):
        raise Failure("invalid_configuration")
    if "schema" in value and (type(value["schema"]) is not int or value["schema"] != 1) or "enabled" in value and type(value["enabled"]) is not bool:
        raise Failure("invalid_configuration")
    return value


def public_config(config):
    value = {key: config.get(key, "") for key in ("chat_id", "host_label", "tag")}
    if config.get("message_thread_id") is not None:
        value["message_thread_id"] = config["message_thread_id"]
    return value


def legacy_config(data):
    result = {}
    allowed = {"TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "SSH_NOTIFY_HOST", "SSH_NOTIFY_TAG"}
    try:
        for line in data.decode("utf-8").splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.fullmatch(r"([A-Z_]+)=(?:'([^'\n]*)'|\"([^\"\n]*)\"|([A-Za-z0-9_:@./+-]*))", line.strip())
            if not match or match[1] not in allowed or match[1] in result:
                raise ValueError()
            value = next(part for part in match.groups()[1:] if part is not None)
            if any(c in value for c in "$`\\"):
                raise ValueError()
            result[match[1]] = value
        if set(result) != allowed:
            raise ValueError()
        config = {"schema": 1, "enabled": True, "token": result["TELEGRAM_BOT_TOKEN"], "chat_id": result["TELEGRAM_CHAT_ID"], "host_label": result["SSH_NOTIFY_HOST"], "tag": result["SSH_NOTIFY_TAG"].lstrip("#")}
        return configuration(config, require_token=True)
    except (ValueError, UnicodeError, Failure):
        raise Failure("foreign_installation")


def effective_pam(root):
    if root != Path("/"):
        path = root / "etc/ssh/sshd_config"
        if path.exists():
            data = read(path, root).decode("utf-8")
            values = re.findall(r"(?im)^\s*UsePAM\s+(yes|no)\s*(?:#.*)?$", data)
            return not values or values[0].lower() == "yes"
        return True
    try:
        result = subprocess.run(["/usr/sbin/sshd", "-T"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"}, timeout=5, check=True)
        if len(result.stdout) > 65536:
            return False
        fields = dict(line.split(None, 1) for line in result.stdout.decode().splitlines() if " " in line)
        return fields.get("usepam") == "yes" and fields.get("pamservicename", "sshd") == "sshd"
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def snapshot(root):
    files = {}
    revision = hashlib.sha256()
    for name in OBSERVED:
        data = read(root / name, root, secret=name in (CONFIG, LEGACY_CONFIG, MANIFEST))
        files[name] = data
        if data is None:
            identity = b"absent"
        else:
            info = (root / name).lstat()
            identity = (str(info.st_uid) + ":" + str(info.st_gid) + ":" + str(info.st_mode) + ":" + str(info.st_ino) + ":" + str(info.st_mtime_ns)).encode() + b":" + digest(data).encode()
        revision.update(name.encode() + b"\0" + identity + b"\0")
    pam_enabled = effective_pam(root)
    revision.update(b"pam=yes" if pam_enabled else b"pam=no")
    return files, revision.hexdigest(), pam_enabled


def recovery_paths(root, ignore=None):
    directory = root / "var/lib"
    if not directory.is_dir():
        return []
    found = []
    with os.scandir(directory) as listing:
        for index, entry in enumerate(listing):
            if index >= 4096:
                return found or [directory]
            if entry.name.startswith(".ssh-hub-login-transaction-") and Path(entry.path) != ignore:
                found.append(Path(entry.path))
                if len(found) == 4:
                    break
    return found


def inspect(root=Path("/"), ignore_transaction=None):
    root = Path(root)
    files, revision, pam_enabled = snapshot(root)
    result = {"schema": 1, "state": "absent", "enabled": False, "has_token": False, "configuration": dict(EMPTY_CONFIG), "revision": revision, "paths": ["/" + name for name in (PAM, HELPER, CONFIG, UNIT, STATE, "run/ssh-hub-login-notify", "var/lib/ssh-hub-login-notify.lock")], "warnings": []}
    if not pam_enabled:
        result["warnings"].append("SSH PAM отключён или использует другой сервис; автоматически менять параметры sshd нельзя.")
    recovery = recovery_paths(root, ignore_transaction)
    if recovery:
        result["paths"] += ["/" + str(path.relative_to(root)) for path in recovery]
        result["warnings"].append("Обнаружена незавершённая транзакция. Нужна проверка администратором; новые изменения заблокированы, закрытые снимки для отката сохранены на сервере.")
    if files[PAM] is None:
        result["state"] = "foreign"; result["warnings"].append("Файл PAM sshd отсутствует."); return result
    try:
        lines = files[PAM].decode("utf-8").splitlines()
        managed_hooks = [line for line in lines if "ssh-hub-login-notify" in line and not line.lstrip().startswith("#")]
        legacy_hooks = [line for line in lines if "ssh-login-telegram" in line and not line.lstrip().startswith("#")]
        other_hooks = [line for line in lines if not line.lstrip().startswith("#") and "pam_exec.so" in line and "telegram" in line.lower() and line not in (HOOK, LEGACY_HOOK)]
        if other_hooks:
            raise Failure("foreign_installation")
        managed_files = any(files[name] is not None for name in (HELPER, CONFIG, UNIT, MANIFEST))
        legacy_files = files[LEGACY_HELPER] is not None or files[LEGACY_CONFIG] is not None
        if managed_files or managed_hooks:
            manifest = json.loads(files[MANIFEST] or b"null")
            config = configuration(json.loads(files[CONFIG] or b"null"), require_token=True)
            if not isinstance(manifest, dict) or set(manifest) != {"schema", "kind", "helper_sha256", "unit_sha256"} or type(manifest["schema"]) is not int or manifest["schema"] != 1 or manifest["kind"] != "ssh-hub-login-notify" or type(config.get("enabled")) is not bool or config.get("schema") != 1 or files[HELPER] is None or files[UNIT] is None or manifest["helper_sha256"] != digest(files[HELPER]) or manifest["unit_sha256"] != digest(UNIT_TEXT.encode()) or files[UNIT] != UNIT_TEXT.encode() or managed_hooks != [HOOK] or legacy_hooks or legacy_files:
                raise Failure("foreign_installation")
            result.update(state="managed", enabled=config.get("enabled") is True, has_token=True, configuration=public_config(config))
        elif legacy_files or legacy_hooks:
            if legacy_hooks != [LEGACY_HOOK] or files[LEGACY_HELPER] is None or digest(files[LEGACY_HELPER]) != KNOWN_LEGACY_SHA256 or files[LEGACY_CONFIG] is None:
                raise Failure("foreign_installation")
            config = legacy_config(files[LEGACY_CONFIG])
            result.update(state="legacy", enabled=True, has_token=True, configuration=public_config(config))
            result["paths"] += ["/" + LEGACY_HELPER, "/" + LEGACY_CONFIG]
            result["warnings"].append("Распознана прежняя настройка. Для управления нужно явно принять её под управление SSH Hub.")
        else:
            for relative in (str(Path(HELPER).parent), str(Path(CONFIG).parent), STATE):
                directory = root / relative
                if directory.exists() and next(directory.iterdir(), None) is not None:
                    result["warnings"].append("В каталоге /" + relative + " остались посторонние файлы; они сохранены, новая установка в этот каталог запрещена.")
        status = read(root / STATE / "status.json", root, 4096, secret=True) if result["state"] == "managed" else None
        if status:
            delivery = json.loads(status)
            if isinstance(delivery, dict) and delivery.get("state") in ("ready", "sent", "failed", "retry"):
                result["delivery"] = {"state": delivery["state"]}
                if isinstance(delivery.get("date"), str) and len(delivery["date"]) <= 80:
                    try:
                        date = datetime.datetime.fromisoformat(delivery["date"].replace("Z", "+00:00"))
                        if date.utcoffset() == datetime.timedelta(0):
                            result["delivery"]["date"] = delivery["date"]
                    except ValueError:
                        pass
    except (ValueError, UnicodeError, TypeError, KeyError, Failure):
        result.update(state="foreign", enabled=False, has_token=False, configuration=dict(EMPTY_CONFIG))
        result["warnings"].append("Обнаружена изменённая или неизвестная настройка; автоматическая перезапись и удаление запрещены.")
    return result


def systemctl(arguments):
    try:
        result = subprocess.run(["/usr/bin/systemctl"] + arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"}, timeout=20, check=False)
        if result.returncode:
            raise Failure("service_failed")
    except (OSError, subprocess.SubprocessError):
        raise Failure("service_failed")


def platform_check():
    if not sys.platform.startswith("linux") or os.geteuid() != 0 or sys.version_info < (3, 9) or not Path("/run/systemd/system").is_dir():
        raise Failure("unsupported")
    if not any(Path(path).is_file() for path in ("/lib/x86_64-linux-gnu/security/pam_exec.so", "/usr/lib/x86_64-linux-gnu/security/pam_exec.so", "/lib/aarch64-linux-gnu/security/pam_exec.so", "/usr/lib/aarch64-linux-gnu/security/pam_exec.so", "/lib64/security/pam_exec.so", "/usr/lib64/security/pam_exec.so", "/usr/lib/security/pam_exec.so")):
        raise Failure("unsupported")


def mkdir(path, root, mode=0o700):
    safe_parents(path / "placeholder", root)
    if os.path.lexists(path):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner(root) or info.st_mode & (0o077 if mode == 0o700 else 0o022):
            raise Failure("unsafe_path")
        return False
    path.mkdir(mode=mode); os.chmod(path, mode); return True


def replace(path, data, root, mode=0o600, exclusive=False):
    safe_parents(path, root)
    temporary = path.parent / ("." + path.name + "." + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode); stream.write(data); stream.flush(); os.fsync(stream.fileno())
        if exclusive:
            try:
                os.link(temporary, path)
            except FileExistsError:
                raise Failure("revision_changed")
        else:
            os.replace(temporary, path)
    finally:
        with contextlib.suppress(OSError):
            temporary.unlink()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def execute(payload, root=Path("/"), command=systemctl, preflight=platform_check):
    root = Path(root)
    allowed = {"schema", "action", "expected_revision", "config", "token", "adopt_legacy", "helper", "helper_sha256"}
    if not isinstance(payload, dict) or set(payload) - allowed or type(payload.get("schema")) is not int or payload.get("schema") != 1 or payload.get("action") not in ("inspect", "install", "configure", "enable", "disable", "remove"):
        raise Failure("invalid_payload")
    action = payload["action"]
    if action == "inspect":
        return inspect(root)
    if not isinstance(payload.get("expected_revision"), str) or not re.fullmatch(r"[a-f0-9]{64}", payload["expected_revision"]):
        raise Failure("invalid_payload")
    if type(payload.get("adopt_legacy", False)) is not bool or "token" in payload and not isinstance(payload["token"], str):
        raise Failure("invalid_payload")
    preflight()
    if not effective_pam(root):
        raise Failure("pam_disabled")
    # inspect never creates this root-owned lock or any other file.
    lockpath = root / "var/lib/ssh-hub-login-notify.lock"
    safe_parents(lockpath, root)
    descriptor = os.open(lockpath, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != owner(root) or info.st_mode & 0o077:
            raise Failure("unsafe_path")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure("busy")
        current = inspect(root)
        if recovery_paths(root):
            raise Failure("recovery_required")
        if current["revision"] != payload["expected_revision"]:
            raise Failure("revision_changed")
        if current["state"] == "foreign":
            raise Failure("foreign_installation")
        adopting = current["state"] == "legacy"
        if adopting and (action != "install" or not payload.get("adopt_legacy")):
            raise Failure("legacy_requires_adoption")
        if action == "install" and current["state"] == "managed":
            raise Failure("already_installed")
        if action == "install":
            for relative in (str(Path(HELPER).parent), str(Path(CONFIG).parent), STATE):
                directory = root / relative
                if directory.exists() and next(directory.iterdir(), None) is not None:
                    raise Failure("foreign_installation")
        if action != "install" and current["state"] == "absent":
            raise Failure("not_installed")
        files, revision, _ = snapshot(root)
        if revision != current["revision"]:
            raise Failure("revision_changed")
        oldconfig = legacy_config(files[LEGACY_CONFIG]) if adopting else json.loads(files[CONFIG]) if files[CONFIG] else None
        config = None
        if action != "remove":
            config = dict(oldconfig or {})
            if action in ("install", "configure"):
                incoming = payload.get("config")
                if incoming is None and adopting:
                    incoming = public_config(oldconfig)
                if not isinstance(incoming, dict) or set(incoming) - {"chat_id", "host_label", "tag", "message_thread_id"}:
                    raise Failure("invalid_configuration")
                config = dict(incoming)
                config.update(schema=1, enabled=True if action == "install" else oldconfig["enabled"], token=payload.get("token") or (oldconfig or {}).get("token", ""))
            elif action in ("enable", "disable"):
                config["enabled"] = action == "enable"
            configuration(config, require_token=True)
        helper = None
        if action == "install":
            try:
                helper = base64.b64decode(payload.get("helper", ""), validate=True)
                if len(helper) > 100000 or not helper or digest(helper) != payload.get("helper_sha256"):
                    raise ValueError()
                ast.parse(helper.decode("utf-8"))
            except (ValueError, UnicodeError, SyntaxError, TypeError):
                raise Failure("invalid_payload")
        return mutate(root, action, files, current, config, helper, adopting, command)
    finally:
        os.close(descriptor)


def mutate(root, action, files, current, config, helper, adopting, command):
    # Private, bounded preimages permit rollback; no backup leaves the server.
    transaction = Path(tempfile.mkdtemp(prefix=".ssh-hub-login-transaction-", dir=root / "var/lib"))
    os.chmod(transaction, 0o700)
    replace(transaction / "transaction.json", encoded({"schema": 1, "state": "preparing", "action": action, "revision": current["revision"]}), root)
    snapshots = {}
    for index, name in enumerate(OBSERVED):
        data = files[name]
        if data is not None:
            backup = transaction / str(index)
            replace(backup, data, root)
            snapshots[name] = ((root / name).stat().st_mode & 0o7777, (root / name).stat().st_gid)
    replace(transaction / "transaction.json", encoded({"schema": 1, "state": "pending", "action": action, "revision": current["revision"], "files": [{"path": "/" + name, "backup": str(OBSERVED.index(name)), "mode": mode, "uid": owner(root), "gid": group} for name, (mode, group) in snapshots.items()]}), root)
    created = []
    touched = set()
    effects = {}
    def change(relative, data, mode=0o600):
        existing = read(root / relative, root, secret=relative in (CONFIG, LEGACY_CONFIG, MANIFEST))
        if existing != files[relative]:
            raise Failure("revision_changed")
        if data is None:
            (root / relative).unlink()
        else:
            replace(root / relative, data, root, mode, exclusive=files[relative] is None)
        touched.add(relative); effects[relative] = data
    committed = False
    try:
        # Revalidate after backup and immediately before the first mutation.
        if snapshot(root)[1] != current["revision"]:
            raise Failure("revision_changed")
        if action == "install":
            for relative, mode in (("usr/local/lib/ssh-hub-login-notify", 0o755), ("etc/ssh-hub-login-notify", 0o700), (STATE, 0o700), (STATE + "/queue", 0o700)):
                path = root / relative
                if mkdir(path, root, mode):
                    created.append(path)
            for relative, data, mode in ((HELPER, helper, 0o755), (UNIT, UNIT_TEXT.encode(), 0o644), (MANIFEST, encoded({"schema": 1, "kind": "ssh-hub-login-notify", "helper_sha256": digest(helper), "unit_sha256": digest(UNIT_TEXT.encode())}), 0o600)):
                change(relative, data, mode)
        if config is not None:
            change(CONFIG, encoded(config))
        if action in ("install", "remove"):
            lines = files[PAM].decode("utf-8").splitlines(keepends=True)
            removed = LEGACY_HOOK if adopting else HOOK
            lines = [line for line in lines if line.rstrip("\r\n") != removed]
            pam = "".join(lines)
            if action == "install":
                if pam and not pam.endswith("\n"):
                    pam += "\n"
                pam += HOOK + "\n"
            change(PAM, pam.encode(), snapshots[PAM][0])
            os.chown(root / PAM, owner(root), snapshots[PAM][1])
        if action == "remove":
            command(["disable", "--now", UNIT_NAME])
            for relative in (HELPER, CONFIG, UNIT, MANIFEST):
                change(relative, None)
            command(["daemon-reload"])
        else:
            command(["daemon-reload"])
            command(["enable", "--now", UNIT_NAME] if config["enabled"] else ["disable", "--now", UNIT_NAME])
            if config["enabled"] and action == "configure":
                command(["restart", UNIT_NAME])
            if root == Path("/") and config["enabled"]:
                deadline = time.monotonic() + 4
                while True:
                    try:
                        info = Path("/run/ssh-hub-login-notify/events.sock").lstat()
                        if stat.S_ISSOCK(info.st_mode) and info.st_uid == 0 and info.st_mode & 0o077 == 0:
                            command(["is-active", "--quiet", UNIT_NAME]); break
                    except OSError:
                        pass
                    if time.monotonic() >= deadline:
                        raise Failure("service_failed")
                    time.sleep(.1)
        if adopting:
            for relative in (LEGACY_HELPER, LEGACY_CONFIG):
                change(relative, None)
        if action == "remove":
            # Only fixed root-owned queue/status artifacts are removed. Unknown
            # children remain for manual review instead of recursive deletion.
            queue = root / STATE / "queue"
            if queue.is_dir() and not queue.is_symlink():
                for child in itertools.islice(queue.iterdir(), 128):
                    if re.fullmatch(r"[a-f0-9]{32}\.json", child.name):
                        with contextlib.suppress(OSError, Failure):
                            read(child, root, 5120, secret=True); child.unlink()
                with contextlib.suppress(OSError):
                    queue.rmdir()
            for relative in (STATE + "/status.json",):
                with contextlib.suppress(OSError, Failure):
                    if read(root / relative, root, 4096, secret=True) is not None:
                        (root / relative).unlink()
            for relative in (str(Path(HELPER).parent), str(Path(CONFIG).parent), STATE):
                with contextlib.suppress(OSError):
                    (root / relative).rmdir()
        final = inspect(root, ignore_transaction=transaction)
        if final["state"] != ("absent" if action == "remove" else "managed"):
            raise Failure("verification_failed")
        committed = True
        return final
    except BaseException as error:
        rollback_ok = True
        if UNIT in touched and effects.get(UNIT) is not None:
            try:
                command(["disable", "--now", UNIT_NAME])
            except BaseException:
                rollback_ok = False
        for relative in reversed(OBSERVED):
            if relative not in touched:
                continue
            try:
                if read(root / relative, root, secret=relative in (CONFIG, LEGACY_CONFIG, MANIFEST)) != effects[relative]:
                    raise Failure("revision_changed")
                index = OBSERVED.index(relative)
                if relative in snapshots:
                    mode, group = snapshots[relative]
                    replace(root / relative, (transaction / str(index)).read_bytes(), root, mode)
                    os.chown(root / relative, owner(root), group)
                elif os.path.lexists(root / relative):
                    (root / relative).unlink()
            except BaseException:
                rollback_ok = False
        try:
            command(["daemon-reload"])
            if current["state"] == "managed":
                command(["enable", "--now", UNIT_NAME] if current["enabled"] else ["disable", "--now", UNIT_NAME])
        except BaseException:
            rollback_ok = False
        for path in reversed(created):
            with contextlib.suppress(OSError):
                path.rmdir()
        if not rollback_ok:
            # Leave the private transaction/preimages for administrator repair.
            replace(transaction / "transaction.json", encoded({"schema": 1, "state": "rollback_failed", "action": action, "files": [{"path": "/" + name, "backup": str(OBSERVED.index(name)), "mode": mode, "uid": owner(root), "gid": group} for name, (mode, group) in snapshots.items()]}), root)
            raise Failure("rollback_failed")
        raise error if isinstance(error, Failure) else Failure("interrupted" if isinstance(error, (KeyboardInterrupt, SystemExit)) else "operation_failed")
    finally:
        if committed or not (transaction / "transaction.json").exists() or json.loads((transaction / "transaction.json").read_bytes()).get("state") != "rollback_failed":
            shutil.rmtree(transaction)


def main():
    os.umask(0o077)
    def interrupted(*_):
        raise Failure("interrupted")
    for value in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(value, interrupted)
    try:
        data = sys.stdin.buffer.read(262145)
        if len(data) > 262144:
            raise Failure("invalid_payload")
        status = execute(json.loads(data))
        response = {"ok": True, "status": status}
        output = encoded(response)
        if len(output) > 16384:
            raise Failure("response_limit")
        sys.stdout.buffer.write(output + b"\n"); return 0
    except Failure as error:
        response = {"ok": False, "error": error.code}
    except BaseException:
        response = {"ok": False, "error": "operation_failed"}
    print(json.dumps(response, separators=(",", ":"))); return 1


if __name__ == "__main__":
    raise SystemExit(main())
