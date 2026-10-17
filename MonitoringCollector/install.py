#!/usr/bin/env python3
"""SSH Hub's reviewed installer. JSON payload is read only from SSH stdin."""
import base64
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid


class InstallationFailure(Exception):
    pass


def run_systemctl(arguments):
    result = subprocess.run(["/usr/bin/systemctl"] + arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
    if result.returncode:
        raise InstallationFailure("systemd_failed")


def unit_text(name, python="/usr/bin/python3"):
    return """[Unit]
Description=SSH Hub monitoring collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=api-token:/etc/{name}/token
Environment=SSH_HUB_MONITOR_TOKEN_FILE=%d/api-token
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart={python} /opt/{name}/collector.py --config /opt/{name}/config.json --database /var/lib/{name}/history.sqlite
StateDirectory={name}
StateDirectoryMode=0700
UMask=0077
Restart=on-failure
RestartSec=5
TimeoutStopSec=25
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/{name}

[Install]
WantedBy=multi-user.target
""".format(name=name, python=python)


def validate(payload):
    if not isinstance(payload, dict) or set(payload) != {"instance_id", "port", "token", "collector", "collector_sha256", "config"}:
        raise InstallationFailure("invalid_payload")
    try:
        instance = str(uuid.UUID(payload["instance_id"]))
    except (ValueError, TypeError, AttributeError):
        raise InstallationFailure("invalid_payload")
    if payload["instance_id"] != instance or not isinstance(payload["port"], int) or isinstance(payload["port"], bool) or not 1024 <= payload["port"] <= 65535:
        raise InstallationFailure("invalid_payload")
    token = payload["token"]
    if not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{64}", token):
        raise InstallationFailure("invalid_payload")
    try:
        source = base64.b64decode(payload["collector"], validate=True)
    except (ValueError, TypeError):
        raise InstallationFailure("invalid_payload")
    if len(source) > 100_000 or hashlib.sha256(source).hexdigest() != payload["collector_sha256"]:
        raise InstallationFailure("invalid_payload")
    config = payload["config"]
    if not isinstance(config, dict) or config.get("listen") != "127.0.0.1" or config.get("port") != payload["port"] or len(json.dumps(config).encode()) > 100_000:
        raise InstallationFailure("invalid_payload")
    # Validate using the exact collector version bundled in the app before publish.
    namespace = {"__name__": "ssh_hub_validation", "__file__": "collector.py"}
    try:
        exec(compile(source, "collector.py", "exec"), namespace)
    except Exception:
        raise InstallationFailure("invalid_payload")
    return instance, source, namespace


def preflight():
    if not sys.platform.startswith("linux") or os.geteuid() != 0:
        raise InstallationFailure("root_linux_required")
    if sys.version_info < (3, 9) or not Path("/usr/bin/python3").is_file() or not Path("/run/systemd/system").is_dir():
        raise InstallationFailure("dependencies_required")
    try:
        result = subprocess.run(["/usr/bin/systemctl", "--version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True)
        version = int(result.stdout.splitlines()[0].split()[1])
        if version < 247:
            raise ValueError()
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        raise InstallationFailure("systemd_247_required")


def secure_file(path, data, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        with contextlib.suppress(OSError):
            path.unlink()
        raise


def health(port, token):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request("GET", "/v1/snapshot", headers={"Authorization": "Bearer " + token})
        response = connection.getresponse()
        data = response.read(262145)
        value = json.loads(data)
        return response.status == 200 and len(data) <= 262144 and value.get("version") == 1 and value.get("healthy") is True
    except (OSError, ValueError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def install(payload, root=Path("/"), command=run_systemctl, check=preflight, health_check=health):
    check()
    instance, source, namespace = validate(payload)
    name = "ssh-hub-monitor-" + instance
    program, settings, state, units = [root / part for part in ("opt", "etc", "var/lib", "etc/systemd/system")]
    for parent in (program, settings, state, units):
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or (root == Path("/") and info.st_uid != 0):
            raise InstallationFailure("unsafe_destination")
    destination, credentials, database = program / name, settings / name, state / name
    unit = units / (name + ".service")
    if any(os.path.lexists(path) for path in (destination, credentials, database, unit)):
        raise InstallationFailure("already_exists")
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", payload["port"]))
        except OSError:
            raise InstallationFailure("port_busy")
    created = []
    unit_published = False
    staged_created = False
    success = False
    staged = units / ("." + name + "." + uuid.uuid4().hex + ".staging")
    try:
        destination.mkdir(mode=0o755); os.chmod(destination, 0o755); created.append(destination)
        credentials.mkdir(mode=0o700); created.append(credentials)
        secure_file(destination / "collector.py", source, 0o644)
        secure_file(destination / "config.json", json.dumps(payload["config"], ensure_ascii=False).encode(), 0o644)
        namespace["load_config"](destination / "config.json")
        secure_file(credentials / "token", payload["token"].encode())
        # Keep staging and exclusive publication on the same filesystem: /opt
        # commonly lives on a different mount from /etc/systemd/system.
        secure_file(staged, unit_text(name).encode(), 0o644)
        staged_created = True
        os.link(staged, unit); unit_published = True
        staged.unlink()
        command(["daemon-reload"])
        command(["enable", "--now", name + ".service"])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if health_check(payload["port"], payload["token"]):
                success = True
                return {"version": 1, "ok": True, "instance_id": instance, "port": payload["port"], "unit": name + ".service"}
            time.sleep(.3)
        raise InstallationFailure("health_failed")
    finally:
        if staged_created:
            with contextlib.suppress(OSError):
                staged.unlink()
        if not success:
            if unit_published:
                with contextlib.suppress(Exception):
                    command(["disable", "--now", name + ".service"])
                with contextlib.suppress(Exception):
                    command(["clean", "--what=state", name + ".service"])
                with contextlib.suppress(OSError):
                    unit.unlink()
                with contextlib.suppress(Exception):
                    command(["daemon-reload"])
            # StateDirectory is managed by systemd/DynamicUser and may be under
            # /var/lib/private. Never recurse through its symlink on rollback.
            for path in reversed(created):
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)


def main():
    os.umask(0o077)
    def interrupted(*_):
        raise InstallationFailure("interrupted")
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, interrupted)
    try:
        data = sys.stdin.buffer.read(262145)
        if len(data) > 262144:
            raise InstallationFailure("invalid_payload")
        result = install(json.loads(data))
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except InstallationFailure as error:
        print(json.dumps({"version": 1, "ok": False, "error": str(error)}, separators=(",", ":")))
    except Exception:
        print('{"version":1,"ok":false,"error":"installation_failed"}')
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
