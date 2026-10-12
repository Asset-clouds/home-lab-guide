# Setup day checklist

One page. Tick as you go. Detail for each step is in the linked docs.

## Have ready beforehand

- [ ] USB stick with the Ubuntu Server 24.04 LTS ISO written to it
- [ ] Ethernet cable (use it for the install even if you go WiFi later)
- [ ] Keyboard and monitor for the server
- [ ] SSH public key from your laptop (`cat ~/.ssh/id_ed25519.pub`; `ssh-keygen -t ed25519` if there isn't one)
- [ ] A domain, with its nameservers already switched to Cloudflare. Check from your laptop:
  ```bash
  dig +short NS example.com     # should show the two *.ns.cloudflare.com names
  ```
  If it still shows the registrar's nameservers, don't panic: the tunnel steps can wait until it flips.
- [ ] Tailscale account, signed in on your laptop
- [ ] The WiFi name and password, in case Ethernet isn't an option

## On the day, in order

1. [ ] Install Ubuntu Server from the USB, enable OpenSSH, paste in the SSH key ([server-setup.md](server-setup.md))
2. [ ] From your laptop, `ssh YOUR_USER@SERVER_IP` works with the key
3. [ ] Clone your copy of this repo:
   ```bash
   sudo apt install -y git
   git clone https://github.com/YOUR_GITHUB_USER/homelab.git ~/homelab && cd ~/homelab
   ```
4. [ ] Bootstrap (try `--dry-run` first), then log out and back in:
   ```bash
   sudo ./scripts/bootstrap.sh
   ```
5. [ ] Join Tailscale, then check you can SSH over the tailnet from your laptop ([tailscale.md](tailscale.md)):
   ```bash
   sudo tailscale up --ssh
   ```
6. [ ] Make the env file with real secrets:
   ```bash
   cp docker/.env.example docker/.env
   python3 -c "import secrets; print(secrets.token_hex(32))"   # run twice, one per secret
   nano docker/.env
   ```
7. [ ] Start the containers:
   ```bash
   cd docker && docker compose up -d && docker compose ps
   ```
8. [ ] Pull the model (a few GB, so start it early): `ollama pull llama3.1:8b`
9. [ ] Uptime Kuma over Tailscale: make the admin account, add the monitors and the two Push monitors, save the push URLs in `/etc/homelab` ([uptime-kuma.md](uptime-kuma.md))
10. [ ] Plug in the backup SSD, mount it at `/mnt/backup` ([backups.md](backups.md))
11. [ ] Install the cron jobs and test them:
    ```bash
    cd ~/homelab && sudo ./scripts/install-cron.sh
    sudo homelab-backup --dry-run && sudo homelab-backup
    sudo homelab-health
    ```
12. [ ] Tunnel, if the nameservers have flipped (otherwise another day): [cloudflare-tunnel.md](cloudflare-tunnel.md)
13. [ ] Tell `check.sh` your domain:
    ```bash
    echo 'DOMAIN=example.com' | sudo tee /etc/homelab/check.conf
    ```
14. [ ] Final check, last thing you run (add `--local` if the tunnel isn't done yet):
    ```bash
    sudo ./scripts/check.sh
    ```

Done when check.sh has no `[FAIL]` lines. If something fails, the runbook in the [README](../README.md#runbook) says where to look.
