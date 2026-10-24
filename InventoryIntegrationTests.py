#!/usr/bin/env python3
"""Disposable loopback SSH fixture. Verifies transport/protocol, not a real Linux OS."""
import contextlib
import getpass
import pathlib
import subprocess
import sys
import tempfile
import time

from TunnelIntegrationTests import free_port, reachable


@contextlib.contextmanager
def fixture(root, command):
    root.mkdir(mode=0o700)
    daemon = None
    try:
        for name in ("host", "client"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "Disposable inventory fixture", "-f", str(root / name)], check=True)
        (root / "command").write_text(command)
        (root / "mode").write_text("normal")
        # ForceCommand checks that the app sent the fixed Linux collector intact.
        # It returns synthetic marked facts; arbitrary shell text is never executed.
        handler = root / "handler.py"
        handler.write_text('''import os,pathlib,sys,time
root=pathlib.Path(__file__).parent
if os.environ.get("SSH_ORIGINAL_COMMAND", "") != (root/"command").read_text():
    print("Unexpected collector command", file=sys.stderr);sys.exit(91)
(root/"started").write_text("started")
mode=(root/"mode").read_text()
if mode=="slow":time.sleep(2.5)
if mode=="oversized":print("x"*262145);sys.exit(0)
if mode=="empty":print("No inventory markers");sys.exit(0)
print("""__SSH_HUB_INVENTORY_manufacturer__
Fixture Vendor
__SSH_HUB_INVENTORY_model__
Loopback Machine
__SSH_HUB_INVENTORY_operatingSystem__
Debian fixture / synthetic inventory
__SSH_HUB_INVENTORY_memoryModules__
format=dmidecode
Physical Memory Array
Number Of Devices: 2

Memory Device
Locator: DIMM A1
Size: 16 GB
Manufacturer: Fixture RAM Vendor

__SSH_HUB_INVENTORY_motherboard__
Manufacturer: Fixture Board Vendor
Product Name: Demo Board
__SSH_HUB_INVENTORY_bios__
Vendor: Fixture Firmware
Version: 1.2
__SSH_HUB_INVENTORY_disks__
format=lsblk-pairs
NAME="nvme0n1" SIZE="1000000000000" TYPE="disk" MODEL="Fixture SSD" SERIAL="DEMO123" REV="1.2" TRAN="nvme" ROTA="0"
__SSH_HUB_INVENTORY_diskSMART__
format=smartctl-gron-v1
device=nvme0n1
json.device.name = "/dev/nvme0n1";
json.device.protocol = "NVMe";
json.model_name = "Fixture SSD";
json.serial_number = "DEMO123";
json.smart_status.passed = true;
json.temperature.current = 39;
json.power_on_time.hours = 1234;
json.nvme_smart_health_information_log.percentage_used = 12;
exit=0
end
__SSH_HUB_INVENTORY_storageUsage__
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/demo1 1000000 650000 300000 69% /
__SSH_HUB_INVENTORY_listeningPorts__
format=ss
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))
udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:*
__SSH_HUB_INVENTORY_interfaces__
eth0 aa:bb:cc:dd:ee:ff
inet 192.0.2.44/24""")
''')
        launch = root / "handler.sh"
        launch.write_text('#!/bin/sh\nexec "' + sys.executable.replace('"', '\\"') + '" "' + str(handler).replace('"', '\\"') + '"\n')
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
        config.write_text("Host inventory-test\n" + common + f' LocalForward {unused} 127.0.0.1:{port}\n PermitLocalCommand yes\n LocalCommand /usr/bin/touch "{root}/should-not-exist"\n RemoteCommand /usr/bin/false\n ForkAfterAuthentication yes\nHost through-hop\n' + common + " ProxyJump hop\nHost hop\n" + common)
        config.chmod(0o600)
        yield config, unused
    finally:
        # Owned slow handlers finish naturally; no unrelated process is signalled.
        time.sleep(2.6)
        if daemon and daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=3)
            except subprocess.TimeoutExpired:
                daemon.kill(); daemon.wait()


def main(binary):
    with tempfile.TemporaryDirectory(prefix="ssh-hub-inventory-integration-", dir="/private/tmp") as directory:
        root = pathlib.Path(directory)
        command = subprocess.run([str(binary), "--command"], check=True, capture_output=True, text=True, timeout=5).stdout.rstrip("\n")
        subprocess.run([str(binary), "--model", str(root / "model")], check=True, timeout=10)
        subprocess.run([str(binary), "--policy", str(root / "policy")], check=True, timeout=15)
        with fixture(root / "ssh", command) as (config, unused):
            ssh = root / "ssh"
            before = (ssh / "known_hosts").read_bytes()
            for alias in ("inventory-test", "through-hop"):
                subprocess.run([str(binary), "--collect", str(config), alias], check=True, timeout=15)
            for mode, action in (("oversized", "--oversized"), ("empty", "--empty")):
                (ssh / "mode").write_text(mode)
                subprocess.run([str(binary), action, str(config), "through-hop"], check=True, timeout=15)
            (ssh / "mode").write_text("slow")
            (ssh / "started").unlink(missing_ok=True)
            subprocess.run([str(binary), "--cancel", str(config), "through-hop", str(ssh / "started")], check=True, timeout=12)
            subprocess.run([str(binary), "--timeout", str(config), "through-hop"], check=True, timeout=6)
            untrusted = ssh / "untrusted-config"
            untrusted.write_text(config.read_text().replace(str(ssh / "known_hosts"), str(ssh / "empty_known_hosts")))
            (ssh / "mode").write_text("normal")
            (ssh / "started").unlink(missing_ok=True)
            subprocess.run([str(binary), "--reject", str(untrusted), "through-hop"], check=True, timeout=10)
            assert not (ssh / "started").exists(), "Untrusted SSH reached collector"
            assert (ssh / "known_hosts").read_bytes() == before, "Known host data changed"
            assert (ssh / "empty_known_hosts").read_bytes() == b"", "Unknown host key accepted"
            assert not (ssh / "should-not-exist").exists(), "Inherited LocalCommand executed"
            assert not reachable(unused), "Inherited LocalForward opened"
    print("PASS Inventory owned localhost fixture: direct/ProxyJump SSH, unchanged command and trust, bounded parse, cancellation/deadline, no inherited forwards/commands")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 InventoryIntegrationTests.py /path/to/inventory-integration-tests")
    main(pathlib.Path(sys.argv[1]).resolve())
