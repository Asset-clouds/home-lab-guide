# Server setup (Day 1)

Ubuntu Server 24.04 LTS on a small always-on PC (I used a second-hand HP ProDesk 400 G3 Mini), then Tailscale and Docker.

Order: install Ubuntu, harden SSH, firewall, updates, Tailscale, Docker.

## Quick way

Once Ubuntu is installed and you've confirmed SSH key login works from your laptop (step 2 and the first part of step 4), you can skip most of the manual steps below. On the server:

```bash
sudo apt install -y git
git clone https://github.com/YOUR_GITHUB_USER/homelab.git ~/homelab
cd ~/homelab
sudo ./scripts/bootstrap.sh
```

It updates the system, hardens SSH (only if your key is in place), sets up ufw and fail2ban, and installs Docker, Tailscale, cloudflared and Ollama. Add `--dry-run` to see what it would do first, or `--skip-ollama` to leave Ollama out. It's safe to re-run. It finishes with a checklist of what's left to do by hand (`tailscale up --ssh`, `cloudflared tunnel login`, pulling the model).

The rest of this doc is the manual version, so you know what the script did and can fix things if one step goes wrong.

## Before you start

- A USB stick (8 GB+) and the Ubuntu Server 24.04 LTS ISO from <https://ubuntu.com/download/server>.
- Write the ISO to the stick with balenaEtcher or Raspberry Pi Imager from your laptop.
- An Ethernet cable for the install, if you can. The installer handles WiFi, but Ethernet is much less fiddly. Switch to WiFi afterwards.
- Your SSH public key from your laptop: `cat ~/.ssh/id_ed25519.pub`
- A keyboard and monitor for the first boot. After that it can run headless.

## 1. BIOS

Open the BIOS setup at power-on (on HP machines it's **F10**, and F9 is the boot menu; other makes often use F2 or Del).

- Boot order: USB first for the install.
- Set **After Power Loss** to power on, so it comes back after a power cut.
- Turn off any sleep/power-saving options that suspend the machine.

## 2. Install Ubuntu Server

Boot from the USB and go through the installer:

- Language and keyboard: English (UK).
- Install type: Ubuntu Server (not minimized).
- Network: use Ethernet if connected. For WiFi, pick your network and enter the password.
- Storage: use the whole internal disk, default layout (LVM is fine).
- Name the server something short, e.g. `homelab`. Pick a username.
- Tick **Install OpenSSH server**, and import your SSH key if offered.
- Skip the optional snaps (Docker comes from Docker's own repo below).

Reboot, remove the USB, log in.

## 3. WiFi (only if you didn't set it up in the installer)

Edit the netplan file (the filename may differ):

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

```yaml
network:
  version: 2
  wifis:
    wlp2s0:                    # check the name with: ip link
      dhcp4: true
      access-points:
        "YOUR_WIFI_NAME":
          password: "YOUR_WIFI_PASSWORD"
```

```bash
sudo chmod 600 /etc/netplan/*.yaml
sudo netplan try
```

This file holds your WiFi password. Never copy it into the repo.

In the router, give the server a **DHCP reservation** so its local IP doesn't change. It's not critical once Tailscale is working, but it makes the first SSH sessions easier.

## 4. Update, then SSH from your laptop

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y unattended-upgrades curl ufw
sudo dpkg-reconfigure -plow unattended-upgrades
```

Find the IP with `ip a`, then from your laptop:

```bash
ssh YOUR_USER@SERVER_IP
```

## 5. Harden SSH

Make sure key login works **before** doing this, or you'll lock yourself out.

```bash
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
```

```
PasswordAuthentication no
PermitRootLogin no
```

```bash
sudo sshd -t && sudo systemctl restart ssh
```

Keep your current session open and test a second login in another window.

## 6. Firewall (ufw)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status
```

After Tailscale is working (step 7) you can tighten SSH to the tailnet only:

```bash
sudo ufw allow in on tailscale0 to any port 22
sudo ufw delete allow OpenSSH
```

Test over Tailscale first. If you do this over WiFi you lose local SSH, so you'd need the keyboard and monitor if Tailscale breaks.

No public ports need opening. The Cloudflare Tunnel is outbound only.

## 7. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

Open the login URL it prints and sign in. See [tailscale.md](tailscale.md) for the rest.

## 8. Docker

Docker's official apt repo (check <https://docs.docker.com/engine/install/ubuntu/> in case it has changed):

```bash
sudo apt install -y ca-certificates
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER      # log out and in again afterwards
docker run --rm hello-world
```

**Docker and ufw:** Docker publishes ports by editing iptables directly, which bypasses ufw. A container started with `-p 3001:3001` is open to the whole network even if ufw says otherwise. Always bind to localhost: `-p 127.0.0.1:3001:3001`. The compose file in `docker/` already does this.

## 9. Clone this repo onto the server

```bash
sudo apt install -y git
git clone https://github.com/YOUR_GITHUB_USER/homelab.git ~/homelab
```

(If your copy of the repo is private, you'll need to sign in. An SSH deploy key or `gh auth login` on the server both work.)

## Day 1 checklist

- [ ] Ubuntu installed, updates applied
- [ ] SSH key login works, password login off
- [ ] ufw on
- [ ] Tailscale connected, SSH works over the tailnet
- [ ] Docker runs `hello-world`
- [ ] Repo cloned
- [ ] Note what you did in your own log, including anything that differed from this doc
