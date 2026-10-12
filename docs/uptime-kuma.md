# Uptime Kuma

Monitoring for service health, plus CPU and disk. Runs in Docker on `localhost:3001` (host networking), private only.

## Start it

```bash
cd ~/homelab/docker
docker compose up -d uptime-kuma
docker compose ps
```

Reach it from your laptop over Tailscale (see [tailscale.md](tailscale.md)), for example:

```bash
ssh -L 3001:localhost:3001 YOUR_USER@homelab
```

then open <http://localhost:3001>. The first visit asks you to create an admin account. Use a strong password and store it in a password manager, not in this repo.

## What Kuma can and can't do

Kuma checks things from the outside: is a URL up, does a port answer, is a container running. It does **not** read CPU or disk usage by itself. For those, a small script on the server checks the numbers and reports to a Kuma **Push** monitor. If the script reports a problem, or stops reporting, Kuma alerts.

## Monitors to add

Kuma runs with `network_mode: host`, so it sees the server's `127.0.0.1` directly. Local targets use `http://127.0.0.1:PORT`.

Service health (type **HTTP(s)** unless noted):

| Name | Target |
|---|---|
| Hub (local) | `http://127.0.0.1:9000` |
| Open WebUI (local) | `http://127.0.0.1:3100` |
| File Browser (local) | `http://127.0.0.1:3200/health` |
| Ollama | `http://127.0.0.1:11434/api/tags` |
| Hub (public) | `https://example.com/` |

Add a local and a public monitor for each app you put behind the tunnel.

Local checks tell you if a service is down. Public checks tell you if the tunnel is down. If only the public ones fail, it's the tunnel.

### Why host networking

Services are published on `127.0.0.1` on the host (and Ollama listens there too), which a bridge-networked container can't reach. Host networking fixes that, and means no `ports:` entry. Unlike docker-published ports, host networking is subject to ufw, so 3001 stays closed to the LAN as long as ufw doesn't allow it.

### Ollama and ufw

The Open WebUI container (bridge network) has to reach Ollama on the host via `host.docker.internal`, which resolves to the docker bridge gateway, not `127.0.0.1`. So Ollama listens on `0.0.0.0:11434` (set `OLLAMA_HOST=0.0.0.0:11434` in its systemd override) and ufw does the restricting. ufw default-deny applies to host processes, so the LAN can't reach 11434, and one rule lets docker in:

```bash
sudo ufw allow from 172.16.0.0/12 to any port 11434 proto tcp
```

Check from another machine on the LAN that port 11434 does not answer. Kuma itself uses `127.0.0.1`, so it doesn't need this rule.

Host health (type **Push**):

| Name | Reports |
|---|---|
| Host health | CPU, disk, memory OK |
| Nightly backup | backup finished |

Each Push monitor gives you a URL like `http://localhost:3001/api/push/<TOKEN>?status=up&msg=OK`. Treat that token like a password. Keep it in a file on the server, not in this repo.

Set the Push monitors' heartbeat interval a bit longer than the schedule: 5 minutes for the health check script (so about 6 min), and 25 hours for the nightly backup.

## Host health script

The check lives in the repo at `scripts/health.sh`. It reads the push URL from `/etc/homelab/kuma-health-url` (one line, `chmod 600`) and reports CPU and disk to the "Host health" Push monitor. Run it from cron every 5 minutes (`scripts/install-cron.sh` sets this up).

Add the same kind of one-line ping to the end of the backup script ([backups.md](backups.md)) with the "Nightly backup" push URL (`/etc/homelab/kuma-backup-url`).

## Notifications

Settings > Notifications. Pick whatever you'll actually see: email, Telegram, Discord, Pushover and others are built in. Set it as the default for all monitors, and send a test.

Think about what happens if the server or the internet is down: Kuma runs on the server, so it can't tell you the server is dead. A free external monitor (e.g. UptimeRobot) pointed at `https://example.com/` covers that gap.

## Keep it private

Kuma has its own login, but it still should not be public. It's not in the tunnel config, it's bound to `127.0.0.1`, and you reach it over Tailscale only.

## Backups and updates

- The data lives in the `uptime-kuma-data` Docker volume. Include `/var/lib/docker/volumes/` in the backup script (see [backups.md](backups.md)).
- Update with `docker compose pull uptime-kuma && docker compose up -d uptime-kuma`.
