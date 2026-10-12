# Tailscale

Used for remote SSH and private access to Ollama, Open WebUI, File Browser and Uptime Kuma. Nothing here is exposed to the public internet.

## Install on the server

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

Open the URL it prints and sign in. `--ssh` lets Tailscale handle SSH authentication, so you can connect without managing keys for that route.

Check:

```bash
tailscale status
tailscale ip -4
```

## Install on your other devices

Install the Tailscale app on your laptop and phone and sign in to the same account. Then:

```bash
ssh YOUR_USER@homelab
```

(The hostname works through MagicDNS, which is on by default.)

## Admin console tweaks

At <https://login.tailscale.com/admin/machines>:

- **Disable key expiry** for the server. Otherwise it drops off the tailnet after about 180 days and you can't SSH in remotely.
- Turn on two-factor authentication on the identity provider you sign in with (Google, GitHub, etc.).
- Remove devices you no longer use.

## Reaching the private services

Uptime Kuma only listens on `localhost`, and Ollama is blocked from the LAN by ufw (it only lets Docker containers in). Two ways to reach them from your devices:

**1. SSH tunnel (no setup)**

```bash
ssh -L 3001:localhost:3001 -L 11434:localhost:11434 YOUR_USER@homelab
```

Then open <http://localhost:3001> on your laptop.

**2. Tailscale Serve (nicer)** shares a local port with your tailnet only, over HTTPS:

```bash
sudo tailscale serve --bg --https=443 http://localhost:3001      # Uptime Kuma
sudo tailscale serve status
```

It becomes available at `https://homelab.<your-tailnet>.ts.net`. Use a different `--https` port for each additional service (e.g. 8443), or a `--set-path`.

**Never use `tailscale funnel`** for these. Funnel exposes a service to the public internet.

Open WebUI and File Browser are shared the same way (see the comments in `docker/docker-compose.yml`), using plain `--http=PORT` so each keeps its own port. Both have their own logins too, so tailnet access isn't the only barrier.

## Access control (optional, worth doing)

By default every device on your tailnet can reach every other. With only your own devices that is fine. If you ever add someone else or a less trusted device, restrict access in the admin console under Access controls. For example, to allow only your own devices to reach the server:

```json
{
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] }
  ]
}
```

Check the current syntax in the console before saving. It validates the file.

## Ethernet vs WiFi

Tailscale works on either. If the server moves from WiFi to Ethernet later, it reconnects on its own.

## Troubleshooting

```bash
sudo systemctl status tailscaled
tailscale status
tailscale netcheck
```
