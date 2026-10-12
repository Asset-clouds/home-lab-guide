# scripts

| Script | What it does | How to run |
|---|---|---|
| `bootstrap.sh` | Day 1 setup: updates, SSH hardening, ufw, fail2ban, Docker, Tailscale, cloudflared, Ollama, `/etc/homelab` | `sudo ./scripts/bootstrap.sh` (`--dry-run`, `--skip-ollama`) |
| `backup.sh` | Snapshot backup to `/mnt/backup/homelab/YYYY-MM-DD` (rsync hard links, keeps 14) | `sudo ./scripts/backup.sh` (`--dry-run`) |
| `restore.sh` | Lists snapshots and restores a path to a staging folder (or in place, with confirmation) | `./scripts/restore.sh list`, `sudo ./scripts/restore.sh latest /etc/cloudflared` |
| `health.sh` | Checks CPU, disk, memory and services, then pushes to Uptime Kuma | `sudo ./scripts/health.sh` |
| `install-cron.sh` | Links scripts to `/usr/local/bin/homelab-*` and installs the cron jobs | `sudo ./scripts/install-cron.sh` |
| `check.sh` | Post-setup "is everything OK?": services, ufw, SSH, containers, local and public HTTP, Ollama, disk, backups, LAN exposure. Settings in `/etc/homelab/check.conf`. Exits 1 on any `[FAIL]` | `sudo ./scripts/check.sh` (`--local` skips the public checks) |
| `lib.sh` | Shared helpers, sourced by the others | not run directly |
