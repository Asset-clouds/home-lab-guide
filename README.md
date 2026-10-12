# Home lab guide

A step-by-step setup for a small home server that hosts public websites safely and runs a few private tools for yourself. It's the setup I use on my own server, cleaned up so you can follow along and copy it.

- **Public sites** come in through a **Cloudflare Tunnel**: no ports opened on your router, your home IP stays hidden, and HTTPS is handled for you.
- **Private tools** are only reachable over **Tailscale**: a local AI chat (Ollama + Open WebUI with web search), drag-and-drop file uploads (File Browser) and monitoring (Uptime Kuma).
- **Backups** go to an external SSD every night, with 14 days of snapshots and a restore script.
- **Scripts** do the fiddly parts: server hardening, backups, health checks and an "is everything OK?" check.

Throughout the docs, `example.com` stands for your domain, `YOUR_USER` for your login on the server, and `YOUR_GITHUB_USER` for wherever you keep your copy of this repo.

Doing it all in one go? Use the one-page tick list: [docs/setup-day-checklist.md](docs/setup-day-checklist.md).

## What you need

| | |
|---|---|
| A small always-on PC | I used a second-hand HP ProDesk 400 G3 Mini (i5-7400T, 16 GB RAM, 256 GB SSD). Any mini PC or old laptop with 8 GB+ RAM works; 16 GB is better if you want to run an 8B AI model. |
| An external SSD | For backups. Formatted ext4. |
| A domain name | Any registrar. Its DNS moves to Cloudflare (free plan). |
| Accounts | Cloudflare and Tailscale, both free. |
| OS | Ubuntu Server 24.04 LTS |

## Services

| Service | Port | Reached from | Runs as |
|---|---|---|---|
| Hub (landing page) | 9000 | public: `example.com`, `www.example.com` | container (nginx) |
| Uptime Kuma | 3001 | private (Tailscale) | container (host networking) |
| Open WebUI + SearXNG | 3100 | private (Tailscale) | containers |
| File Browser | 3200 | private (Tailscale) | container |
| Ollama (Llama 3.1 8B) | 11434 | private, Docker only | host service |
| cloudflared (the tunnel) | n/a | n/a | host service |
| Tailscale | n/a | n/a | host service |

Private means Tailscale only. Those ports are not in the tunnel config, so Cloudflare never sees them. Containers publish on `127.0.0.1` only, because Docker bypasses ufw.

## Quick start

Docs for each step are linked. Do them in order.

1. Install Ubuntu Server 24.04 and get SSH key login working: [docs/server-setup.md](docs/server-setup.md).
2. Clone your copy of this repo:
   ```bash
   sudo apt install -y git
   git clone https://github.com/YOUR_GITHUB_USER/homelab.git ~/homelab
   cd ~/homelab
   ```
3. Run the bootstrap (updates, SSH hardening, ufw, fail2ban, Docker, Tailscale, cloudflared, Ollama). Try `--dry-run` first if you like, and `--skip-ollama` if you don't want the AI parts. Log out and back in afterwards so the docker group applies.
   ```bash
   sudo ./scripts/bootstrap.sh
   ```
4. Join the tailnet ([docs/tailscale.md](docs/tailscale.md)):
   ```bash
   sudo tailscale up --ssh
   ```
5. Set up the tunnel: `cloudflared tunnel login`, `cloudflared tunnel create homelab`, copy the config to `/etc/cloudflared/config.yml`, `cloudflared tunnel route dns homelab <hostname>` for each hostname, then `sudo cloudflared service install`. Full steps in [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md).
6. Create the env file with real secrets:
   ```bash
   cp docker/.env.example docker/.env
   python3 -c "import secrets; print(secrets.token_hex(32))"   # run twice, one per secret
   nano docker/.env
   ```
7. Start the containers:
   ```bash
   cd docker
   docker compose up -d
   docker compose ps
   ```
8. Pull the model, then share the private tools with your tailnet:
   ```bash
   ollama pull llama3.1:8b
   sudo tailscale serve --bg --http=3100 http://127.0.0.1:3100   # Open WebUI
   sudo tailscale serve --bg --http=3200 http://127.0.0.1:3200   # File Browser
   ```
   Open WebUI's first sign-up becomes the admin. File Browser's first password is in `docker logs filebrowser`: change it straight away.
9. Open Uptime Kuma over Tailscale ([docs/uptime-kuma.md](docs/uptime-kuma.md)), add the monitors and two Push monitors, then put the push URLs in `/etc/homelab` (one line each, `chmod 600`):
   ```bash
   sudoedit /etc/homelab/kuma-health-url
   sudoedit /etc/homelab/kuma-backup-url
   sudo chmod 600 /etc/homelab/kuma-*-url
   ```
10. Mount the backup SSD at `/mnt/backup` ([docs/backups.md](docs/backups.md)), then install the cron jobs (backup at 2am, health check every 5 minutes):
    ```bash
    cd ~/homelab
    sudo ./scripts/install-cron.sh
    sudo homelab-backup --dry-run
    sudo homelab-health
    ```
11. Tell the check script your domain, then run it. Everything should say `[ok]` (warnings are worth reading, `[FAIL]` is not allowed). Use `--local` until the tunnel is up:
    ```bash
    echo 'DOMAIN=example.com' | sudo tee /etc/homelab/check.conf
    sudo ./scripts/check.sh          # or: sudo ./scripts/check.sh --local
    ```
    `check.conf` can also list extra URLs to test (`LOCAL_URLS`, `PUBLIC_URLS`): see the top of `scripts/check.sh`.

## Runbook

First move for almost anything: `sudo ./scripts/check.sh`. It lists what's wrong in one go; the table below says what to do about it.

### Something's broken

| Symptom | First thing to check |
|---|---|
| Site is down publicly but fine locally (`curl -I http://localhost:9000` works) | It's the tunnel. `sudo systemctl status cloudflared`, then `journalctl -u cloudflared -f`. Also `cloudflared tunnel ingress validate`. |
| A container is down | `cd ~/homelab/docker && docker compose ps`, then `docker compose logs --tail=50 <name>`, then `docker compose up -d`. |
| Ollama not answering | `systemctl status ollama`, `curl http://127.0.0.1:11434/api/tags`, `journalctl -u ollama -n 50`. If the host is fine but Open WebUI can't reach it, check the ufw rule: `sudo ufw status` should list 11434 from `172.16.0.0/12`. |
| File Browser uploads fail with "permission denied" | The `uploads` folder was created by Docker as root. `sudo chown -R $USER: ~/homelab/uploads`. |
| Disk full | `df -h /`, `docker system df`, `sudo du -xh / --max-depth=1 \| sort -h \| tail`. `docker image prune` clears old images. Health check alerts at 85% used. |
| Backup didn't run | `tail /var/log/homelab-backup.log`, `mountpoint /mnt/backup` (SSD unplugged or not mounted is the usual cause), `cat /etc/cron.d/homelab`. Try `sudo homelab-backup --dry-run`. |
| Kuma says "Host health" is down | `sudo homelab-health` prints what's wrong (CPU, disk, memory, or a service not active). |
| Can't SSH in | Check Tailscale first: `tailscale status` from your laptop, `sudo systemctl status tailscaled` on the server. If the server is unreachable, plug in a keyboard and monitor. Check it has power and network (WiFi password change, router reboot). |

### Restore from backup

Snapshots live in `/mnt/backup/homelab/YYYY-MM-DD` (newest 14 kept, `latest` points at the newest). By default a restore goes to a staging folder and touches nothing live.

```bash
homelab-restore list                                  # or ./scripts/restore.sh list
sudo homelab-restore latest /etc/cloudflared          # restores to /tmp/restore-<date>
sudo homelab-restore 2026-01-31 /var/lib/docker/volumes/homelab_uptime-kuma-data/_data --in-place
```

`--in-place` shows what would change, asks you to type `yes`, and keeps overwritten files as `*.pre-restore-*`. Stop the container that uses the files first. Usage and caveats are in the header of [scripts/restore.sh](scripts/restore.sh) and in [docs/backups.md](docs/backups.md). Run a test restore once so you know it works. Ollama models aren't backed up: `ollama pull llama3.1:8b` gets them back.

### Update everything

```bash
sudo apt update && sudo apt full-upgrade -y
cd ~/homelab/docker
docker compose pull
docker compose up -d
docker image prune -f
ollama pull llama3.1:8b
```

Then check `docker compose ps` and the public sites. Security updates also install themselves (unattended-upgrades).

### Reboot test

Do this once when everything is set up, and again after any big change.

```bash
sudo reboot
```

Give it a couple of minutes, then: SSH back in over Tailscale, `docker compose ps` (everything `Up`), `systemctl status cloudflared ollama`, `curl -I https://example.com/` from your phone on mobile data, and check Kuma is green. The backup SSD should remount on its own (`nofail` in fstab).

Also set the BIOS to power back on after a power cut ([docs/server-setup.md](docs/server-setup.md) step 1), so the server comes back by itself.

## Design decisions

- **Subdomains, not subpaths.** The tunnel doesn't strip path prefixes, so with `/app` style routes every app would need to know it lives under a prefix. One hostname each means every app is served at its own root. Cloudflare's free Universal SSL covers `*.example.com` (one level), so it costs nothing extra.
- **Uptime Kuma uses host networking.** The services listen on `127.0.0.1` on the host, which a bridge-networked container can't reach. Host networking lets Kuma monitor `http://127.0.0.1:PORT` directly. Unlike published Docker ports, host networking is subject to ufw, so 3001 stays closed to the LAN.
- **Ollama listens on 0.0.0.0:11434, with ufw doing the blocking.** Containers reach Ollama on the host through `host.docker.internal`, which is the Docker bridge address, not `127.0.0.1`. ufw is default-deny and only allows `172.16.0.0/12` (Docker) to port 11434, so the LAN can't reach it. Worth checking from another machine on the LAN once it's up.
- **Ollama runs on the host, not in Docker.** Simpler, and no extra networking layer.
- **HTTP to HTTPS** is Cloudflare's "Always Use HTTPS" setting, not something on the server.
- **Kuma can't read CPU or disk by itself**, so `scripts/health.sh` checks them from cron and reports to a Kuma Push monitor.
- **Llama 3.1 8B** was picked over Mistral 7B for better reasoning. Swap in any model Ollama supports, and set `OLLAMA_MODEL` in `/etc/homelab/check.conf` to match.

## Things to know

- **Backups are same-room only.** An external SSD next to the server won't survive theft or fire. An offsite copy or a second machine elsewhere fixes that.
- **SQLite is backed up live.** A write mid-copy could give a slightly inconsistent database. `STOP_FOR_BACKUP=1` and `STOP_CONTAINERS="..."` in `/etc/homelab/backup.conf` fix it for a few seconds of downtime at 2am.
- **WiFi vs Ethernet.** WiFi works. Ethernet is more reliable for a server, and the tunnel and Tailscale both reconnect on their own after a drop.

## Repo layout

```
README.md
sites/
  README.md
  hub/                  landing page (a starter: make it your own)
docker/
  docker-compose.yml    hub, uptime-kuma, open-webui, searxng, filebrowser
  .env.example          copy to .env (gitignored)
  searxng/settings.yml  web search settings for Open WebUI
uploads/                where File Browser puts uploaded files (gitignored)
config/
  cloudflared/config.yml.example
scripts/
  README.md             what each script does
  bootstrap.sh          Day 1 server setup
  backup.sh             nightly snapshot backup (keeps 14 days)
  restore.sh            list snapshots, restore a path
  health.sh             CPU/disk/memory/services check, pushes to Kuma
  check.sh              post-setup "is everything OK" check
  install-cron.sh       links homelab-* commands, installs cron jobs
  lib.sh                shared helpers
docs/
  server-setup.md       Ubuntu, SSH, firewall, Docker (Day 1)
  tailscale.md          remote and private access
  uptime-kuma.md        monitoring, monitors to add
  cloudflare-tunnel.md  public access, DNS, testing
  backups.md            SSD setup, snapshots, restore
  setup-day-checklist.md  one-page tick list
```

Real credentials never go in this repo. See `.gitignore`.

## Licence

MIT: copy it, change it, use it for anything. See [LICENSE](LICENSE).
