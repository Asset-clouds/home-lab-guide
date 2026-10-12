#!/usr/bin/env bash
# install-cron.sh - schedule the backup (02:00 daily) and health check (every
# 5 minutes). Safe to re-run.
#
#   sudo ./scripts/install-cron.sh
#
# It symlinks the repo scripts into /usr/local/bin as homelab-backup,
# homelab-restore and homelab-health, writes /etc/cron.d/homelab, adds log
# rotation, and creates /etc/homelab/backup.conf (BACKUP_USER=you) if missing.
# If you move the repo, re-run this so the symlinks point at the new place.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

echo "==> Linking scripts into /usr/local/bin"
for name in backup restore health; do
  chmod +x "$SCRIPT_DIR/$name.sh"
  ln -sfn "$SCRIPT_DIR/$name.sh" "/usr/local/bin/homelab-$name"
  echo "    homelab-$name -> $SCRIPT_DIR/$name.sh"
done

echo "==> Config in /etc/homelab"
install -d -m 0700 -o root -g root /etc/homelab
if [[ ! -e /etc/homelab/backup.conf ]]; then
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '# Read by homelab-backup. Environment variables override these.\nBACKUP_USER=%s\n#KEEP_DAYS=14\n#STOP_FOR_BACKUP=0\n' \
      "$SUDO_USER" > /etc/homelab/backup.conf
    chmod 600 /etc/homelab/backup.conf
    echo "    created backup.conf with BACKUP_USER=$SUDO_USER"
  else
    echo "    WARNING: couldn't tell which user to back up. Create /etc/homelab/backup.conf with BACKUP_USER=yourname"
  fi
else
  echo "    backup.conf already exists, left alone"
fi
for f in kuma-health-url kuma-backup-url; do
  [[ -e "/etc/homelab/$f" ]] || echo "    note: /etc/homelab/$f doesn't exist yet (monitoring pings are skipped until it does)"
done

echo "==> Writing /etc/cron.d/homelab"
cat > /etc/cron.d/homelab <<'CRON'
# Managed by homelab scripts/install-cron.sh. Re-run that script rather than editing.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# Nightly backup (logs to /var/log/homelab-backup.log)
0 2 * * * root /usr/local/bin/homelab-backup
# Health check, pushes to Uptime Kuma
*/5 * * * * root /usr/local/bin/homelab-health
CRON
chmod 644 /etc/cron.d/homelab

echo "==> Log rotation for the backup log"
cat > /etc/logrotate.d/homelab-backup <<'LR'
/var/log/homelab-backup.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
LR

cat <<'DONE'

Done. Try them now:
  sudo homelab-backup --dry-run
  sudo homelab-health
DONE
