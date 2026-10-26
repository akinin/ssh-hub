#!/usr/bin/env python3
"""Disposable loopback SSH transport fixtures, not real Linux or RouterOS devices."""
import contextlib
import getpass
import json
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time

from TunnelIntegrationTests import free_port, reachable


def section(name, value):
    return "__SSH_HUB_TOPOLOGY_" + name + "__\n" + value + "\n"


def samples():
    lldp = json.dumps({"lldp": {"interface": {"eth0": {"via": "LLDP", "chassis": {"fixture switch": {"id": {"type": "mac", "value": "02:00:00:00:01:01"}, "mgmt-ip": "192.0.2.10"}}, "port": {"id": {"type": "ifname", "value": "Port 2"}}}}}})
    linux = (section("links", json.dumps([{"ifname": "eth0", "address": "02:00:00:00:00:01", "operstate": "UP", "stats64": {"rx": {"bytes": 1000000}, "tx": {"bytes": 2000000}}}]))
             + section("addresses", json.dumps([{"ifname": "eth0", "addr_info": [{"local": "192.0.2.2", "prefixlen": 24}]}]))
             + section("routes4", json.dumps([{"dst": "default", "gateway": "192.0.2.1", "dev": "eth0"}]))
             + section("routes6", "[]") + section("speeds", "eth0\t1000")
             + section("dns", "nameserver 192.0.2.53") + section("resolved", "") + section("lldp", lldp))
    mac = (section("ifconfig", "eth0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500\n\tether 02:00:00:00:00:01\n\tinet 192.0.2.2 netmask 0xffffff00\n\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active")
           + section("counters", "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\neth0 1500 <Link#6> 02:00:00:00:00:01 10 0 1000000 10 0 2000000 0")
           + section("route4", "gateway: 192.0.2.1\ninterface: eth0") + section("route6", "")
           + section("dns", " nameserver[0] : 192.0.2.53") + section("lldp", lldp))
    router = (section("interfaces", json.dumps({"name": "ether \"WAN\"", "mac": "02:00:00:00:00:01", "running": "true", "disabled": "false"}))
              + section("addresses", json.dumps({"interface": "ether \"WAN\"", "address": "192.0.2.2/24"}))
              + section("counters", json.dumps({"name": "ether \"WAN\"", "rx": "1000000", "tx": "2000000"}))
              + section("ethernet", json.dumps({"name": "ether \"WAN\"", "status": "link-ok", "rate": "1Gbps"}))
              + section("routes", json.dumps({"gateway": "192.0.2.1", "immediate": "192.0.2.1%ether \"WAN\"", "active": "true"}))
              + section("dns", json.dumps({"servers": "192.0.2.53"}))
              + section("neighbors", json.dumps({"interface": "ether \"WAN\"", "mac": "02:00:00:00:01:01", "address": "192.0.2.10", "name": "Fixture \"Core\"", "port": "Port 2", "protocol": "lldp"})))
    return {"linux": linux, "macOS": mac, "routerOS": router}


@contextlib.contextmanager
def fixture(root, commands):
    root.mkdir(mode=0o700)
    daemon = None
    try:
        for name in ("host", "client"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "Disposable topology fixture", "-f", str(root / name)], check=True)
        (root / "commands.json").write_text(json.dumps(commands))
        (root / "samples.json").write_text(json.dumps(samples()))
        (root / "mode").write_text("normal")
        handler = root / "handler.py"
        handler.write_text('''import json,os,pathlib,sys,time
root=pathlib.Path(__file__).parent
commands=json.loads((root/"commands.json").read_text())
collector=next((name for name,command in commands.items() if command==os.environ.get("SSH_ORIGINAL_COMMAND", "")),None)
if collector is None:print("Unexpected collector command",file=sys.stderr);sys.exit(91)
(root/"started").write_text(collector)
mode=(root/"mode").read_text()
if mode=="slow":time.sleep(2.5)
if mode=="oversized":print("x"*524289);sys.exit(0)
if mode=="empty":print("No topology facts");sys.exit(0)
print(json.loads((root/"samples.json").read_text())[collector])
''')
        launch = root / "handler.sh"
        launch.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(handler)) + "\n")
        launch.chmod(0o700)
        port = free_port()
        daemon_config = root / "sshd_config"
        daemon_config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding yes
ForceCommand {launch}
LogLevel ERROR
""")
        with (root / "sshd.log").open("w") as log:
            daemon = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(daemon_config)], stdout=log, stderr=log)
        deadline = time.monotonic() + 4
        while not reachable(port):
            if daemon.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError((root / "sshd.log").read_text())
            time.sleep(.04)
        public = (root / "host.pub").read_text().split()
        known = root / "known_hosts"
        known.write_text(f"[127.0.0.1]:{port} {public[0]} {public[1]}\n")
        (root / "empty_known_hosts").write_text("")
        unused = free_port()
        common = f' HostName 127.0.0.1\n Port {port}\n User {getpass.getuser()}\n IdentityFile "{root}/client"\n IdentitiesOnly yes\n UserKnownHostsFile "{known}"\n'
        config = root / "config"
        config.write_text("Host topology-test\n" + common + f' LocalForward {unused} 127.0.0.1:{port}\n PermitLocalCommand yes\n LocalCommand /usr/bin/touch "{root}/should-not-exist"\n RemoteCommand /usr/bin/false\n ForkAfterAuthentication yes\nHost through-hop\n' + common + " ProxyJump hop\nHost hop\n" + common)
        config.chmod(0o600)
        yield config, unused
    finally:
        # Only our own slow handlers are allowed to drain naturally.
        time.sleep(2.6)
        if daemon and daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=3)
            except subprocess.TimeoutExpired:
                daemon.kill(); daemon.wait()


def main(binary):
    commands = {collector: subprocess.run([str(binary), "--command", collector], check=True, capture_output=True, text=True, timeout=5).stdout.rstrip("\n") for collector in samples()}
    subprocess.run([str(binary), "--local"], check=True, timeout=20)
    with tempfile.TemporaryDirectory(prefix="ssh-hub-topology-integration-", dir="/private/tmp") as directory:
        root = pathlib.Path(directory)
        with fixture(root / "ssh", commands) as (config, unused):
            ssh = root / "ssh"
            before = (ssh / "known_hosts").read_bytes()
            for collector in commands:
                for alias in ("topology-test", "through-hop"):
                    subprocess.run([str(binary), "--collect", str(config), alias, collector], check=True, timeout=15)
            for mode in ("oversized", "empty"):
                (ssh / "mode").write_text(mode)
                subprocess.run([str(binary), "--" + mode, str(config), "through-hop", "linux"], check=True, timeout=15)
            (ssh / "mode").write_text("slow")
            (ssh / "started").unlink(missing_ok=True)
            subprocess.run([str(binary), "--cancel", str(config), "through-hop", "linux", str(ssh / "started")], check=True, timeout=12)
            subprocess.run([str(binary), "--timeout", str(config), "through-hop", "linux"], check=True, timeout=6)
            untrusted = ssh / "untrusted-config"
            untrusted.write_text(config.read_text().replace(str(ssh / "known_hosts"), str(ssh / "empty_known_hosts")))
            (ssh / "mode").write_text("normal")
            (ssh / "started").unlink(missing_ok=True)
            subprocess.run([str(binary), "--reject", str(untrusted), "through-hop", "linux"], check=True, timeout=10)
            assert not (ssh / "started").exists(), "Untrusted SSH reached collector"
            assert (ssh / "known_hosts").read_bytes() == before, "Known host data changed"
            assert (ssh / "empty_known_hosts").read_bytes() == b"", "Unknown host key accepted"
            assert not (ssh / "should-not-exist").exists(), "Inherited LocalCommand executed"
            assert not reachable(unused), "Inherited LocalForward opened"
    print("PASS Topology owned localhost SSH direct/ProxyJump, three exact collector commands, bounded parse, cancel/deadline/trust; no inherited commands or forwards")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 Tests/TopologySSHIntegrationTests.py /path/to/topology-ssh-integration-tests")
    main(pathlib.Path(sys.argv[1]).resolve())
