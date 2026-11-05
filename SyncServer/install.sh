#!/bin/sh
# Run only as root inside a dedicated Debian 13 LXC. No registration or SSH RPC.
set -eu
umask 077
test "$(id -u)" = 0
. /etc/os-release
test "$ID" = debian
test "$VERSION_ID" = 13
for file in server.py accounts.py cloud.py admin.py index.html backup.py ssh-hub-sync-cloud.service ssh-hub-sync-backup.service ssh-hub-sync-backup.timer; do
    test -f "/opt/ssh-hub-sync/$file"
    test ! -L "/opt/ssh-hub-sync/$file"
    chown root:root "/opt/ssh-hub-sync/$file"
    chmod 0644 "/opt/ssh-hub-sync/$file"
done
if ! id ssh-hub-sync >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/ssh-hub-sync --shell /usr/sbin/nologin ssh-hub-sync
fi
install -d -o root -g root -m 0755 /opt/ssh-hub-sync /var/lib/ssh-hub-sync
install -d -o ssh-hub-sync -g ssh-hub-sync -m 0700 /var/lib/ssh-hub-sync/cloud /var/backups/ssh-hub-sync
for unit in ssh-hub-sync-cloud.service ssh-hub-sync-backup.service ssh-hub-sync-backup.timer; do
    install -o root -g root -m 0644 "/opt/ssh-hub-sync/$unit" /etc/systemd/system/
done
systemctl daemon-reload
systemctl enable --now ssh-hub-sync-cloud.service ssh-hub-sync-backup.timer
echo 'Private cloud API installed. Configure HTTPS proxy, then create the administrator using admin.py with hidden TTY input.'
