# Backups

Daily rsync to an external SSD, run by cron at 2am.

Snapshots are kept for 14 days. The scripts do the work; this page covers mounting the SSD and what the scripts do.

## Setup

### 1. Mount the external SSD

```bash
lsblk -f                      # find the SSD and its UUID
sudo mkdir -p /mnt/backup
```

Add to `/etc/fstab` so it mounts on boot (replace the UUID and filesystem type):

```
UUID=<SSD_UUID>  /mnt/backup  ext4  defaults,nofail  0  2
```

`nofail` stops the server hanging at boot if the SSD isn't plugged in.

### 2. The scripts

The real scripts are in [`scripts/`](../scripts/):

- `scripts/backup.sh` makes a dated snapshot in `/mnt/backup/homelab/YYYY-MM-DD` using `rsync --link-dest`, so unchanged files are hard-linked and each snapshot only costs the changes. It keeps the newest 14 (`KEEP_DAYS`), updates a `latest` symlink, and refuses to run if `/mnt/backup` isn't mounted.
- `scripts/restore.sh` lists snapshots and restores a path from one.

What gets backed up: `~/homelab`, `/etc/cloudflared`, `/etc/homelab` and `/var/lib/docker/volumes` (which includes `homelab_uptime-kuma-data`, `homelab_open-webui-data` and the File Browser volumes). Ollama models are left out on purpose. They're several GB and `ollama pull llama3.1:8b` gets them back.

Settings go in `/etc/homelab/backup.conf` (`KEY=VALUE` lines) or the environment:

| Setting | Default | |
|---|---|---|
| `BACKUP_USER` | the sudo user | whose `~/homelab` to back up (cron needs this set; `install-cron.sh` does it) |
| `KEEP_DAYS` | 14 | snapshots to keep |
| `STOP_FOR_BACKUP` | 0 | set to 1 to stop `STOP_CONTAINERS` during the copy |
| `STOP_CONTAINERS` | (none) | compose services to stop, space separated, e.g. `open-webui` |
| `MOUNT` / `DEST` | `/mnt/backup`, `/mnt/backup/homelab` | |

**SQLite caveat:** by default app databases (Open WebUI, Uptime Kuma, or your own app's) are copied while they're running. A write mid-copy could give a slightly inconsistent copy. For a small site that's a low risk, but `STOP_FOR_BACKUP=1` removes it for a few seconds of downtime at 2am.

The SSD needs a Linux filesystem (ext4) for the hard links and permissions to work.

### 3. Cron at 2am

```bash
cd ~/homelab
sudo ./scripts/install-cron.sh
```

This links the scripts to `/usr/local/bin/homelab-backup`, `homelab-restore` and `homelab-health`, and writes `/etc/cron.d/homelab` (backup at 02:00, health check every 5 minutes). Safe to re-run.

### 4. Test

```bash
sudo homelab-backup --dry-run      # shows what would be copied
sudo homelab-backup
tail /var/log/homelab-backup.log
ls /mnt/backup/homelab
```

Then try a restore. An untested backup isn't really a backup:

```bash
homelab-restore list
sudo homelab-restore latest /etc/cloudflared      # goes to /tmp/restore-<date>, live files untouched
```

`--target DIR` picks another folder. `--in-place` restores over the live files, but shows you what would change, asks you to type `yes`, and keeps the overwritten files with a `.pre-restore-` suffix. Stop the container using the files first.

### 5. Uptime Kuma

Put the "Nightly backup" push URL (one line) in `/etc/homelab/kuma-backup-url` (`chmod 600`). The script pings it with `up` on success and `down` on failure. Set the monitor's heartbeat to 25 hours so a missed night alerts. See [uptime-kuma.md](uptime-kuma.md).

## Notes

- The SSD is in the same place as the server, so this doesn't protect against theft, fire or flood. A second machine somewhere else, or an offsite copy, would.
- Check the SSD's free space now and then.
