# Cloudflare Tunnel setup

Public access to your domain (`example.com` below: swap in your own) through a Cloudflare Tunnel. No port forwarding, home IP hidden, SSL handled by Cloudflare.

Steps 1-2 can be done before you have the server. Steps 3-6 run on the server.

## 1. Sign up for Cloudflare

1. Create a free account at <https://dash.cloudflare.com/sign-up>.
2. Turn on two-factor authentication.
3. Add the site `example.com` (Free plan). Cloudflare scans existing DNS records. Check them and delete anything you don't recognise.
4. Cloudflare shows you two nameservers (something like `xxx.ns.cloudflare.com`). Note them down.

## 2. Change the nameservers

1. Log in to wherever the domain was bought.
2. Replace the current nameservers with the two Cloudflare ones.
3. Wait. This can take 1-2 days. Cloudflare emails when the domain is active.
4. Check: `dig NS example.com +short` should show the Cloudflare nameservers.

## 3. Install cloudflared

On the server (Ubuntu 24.04):

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install cloudflared
cloudflared --version
```

If these instructions have changed, use the current ones at <https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/>.

## 4. Authenticate

```bash
cloudflared tunnel login
```

This prints a URL. Open it in a browser, pick `example.com`, and authorise. It saves `cert.pem` to `~/.cloudflared/`.

Then create the tunnel:

```bash
cloudflared tunnel create homelab
```

This prints a tunnel ID and writes `~/.cloudflared/<TUNNEL_ID>.json` (the tunnel credentials).

**Keep `cert.pem` and the `<TUNNEL_ID>.json` file private. Never commit them.**

## 5. Create routes and the HTTP to HTTPS redirect

### Config

Copy the example and fill in the tunnel ID and credentials path:

```bash
sudo mkdir -p /etc/cloudflared
sudo cp config/cloudflared/config.yml.example /etc/cloudflared/config.yml
sudo nano /etc/cloudflared/config.yml
```

If running as a service from `/etc/cloudflared`, also copy the credentials file there and point `credentials-file` at it.

Routes in the config. Each public thing has its own hostname:

| Hostname | Backend |
|---|---|
| `example.com` | `http://localhost:9000` (hub) |
| `www.example.com` | `http://localhost:9000` (hub) |
| `app.example.com` | `http://localhost:5000` (an app of your own, if you add one) |

Open WebUI (3100), File Browser (3200), Ollama (11434) and Uptime Kuma (3001) are **not** in the tunnel. They are private and Tailscale only.

Check the config:

```bash
cloudflared tunnel ingress validate
cloudflared tunnel ingress rule https://www.example.com
```

### DNS

Point each hostname at the tunnel (one command per hostname):

```bash
cloudflared tunnel route dns homelab example.com
cloudflared tunnel route dns homelab www.example.com
cloudflared tunnel route dns homelab app.example.com      # only if you added an app
```

Cloudflare's free Universal SSL certificate covers the apex plus one level of subdomain (`*.example.com`), so all of these are fine. A second level like `a.b.example.com` would not be.

### HTTP to HTTPS redirect

In the Cloudflare dashboard, for `example.com`:

1. SSL/TLS > Overview: set encryption mode to **Full**.
2. SSL/TLS > Edge Certificates: turn on **Always Use HTTPS**.

### Run as a service

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

### Why subdomains

Subdomains were chosen over subpaths (`/app` etc.) because the tunnel doesn't strip path prefixes, so every app would have had to know it lives under a prefix. With a hostname each, every app is served at its own root.

## 6. Test each route

Start the backends first, then test locally and from outside the home network (phone on mobile data, not WiFi).

```bash
curl -I http://localhost:9000    # hub

curl -I https://example.com/
curl -I https://www.example.com/
curl -I http://example.com/    # should redirect to https
```

Checklist:

- [ ] `example.com` loads the hub
- [ ] `www.example.com` loads the hub
- [ ] Any app subdomains you added load, including their CSS/JS
- [ ] `http://` redirects to `https://`
- [ ] Private services are **not** reachable publicly: `chat.example.com` and similar made-up hostnames return 404, and ports 11434, 3001, 3100 and 3200 don't answer from outside
- [ ] Tunnel survives a reboot (`sudo reboot`, then re-test)

Troubleshooting: `journalctl -u cloudflared -f`.

## Fallback: nginx + Let's Encrypt

If the tunnel doesn't work out: install nginx and certbot, forward ports 80 and 443 on the router to the server, point the DNS A record at the home IP, and get a certificate with `sudo certbot --nginx -d example.com -d www.example.com`. This exposes the home IP and needs a dynamic DNS update if the IP changes, so only use it if needed.
