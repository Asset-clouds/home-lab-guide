#!/usr/bin/env bash
# bootstrap.sh - Day 1 setup for the server, after Ubuntu is installed and SSH key
# login works. Automates docs/server-setup.md. Safe to re-run.
#
#   sudo ./scripts/bootstrap.sh [--dry-run] [--skip-ollama]
#
#   --dry-run      only print what would be done
#   --skip-ollama  don't install Ollama
set -euo pipefail

DRY_RUN=0
SKIP_OLLAMA=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-ollama) SKIP_OLLAMA=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo $0 $*" >&2
  exit 1
fi

# The normal user who ran sudo. Used for the SSH key check and docker group.
TARGET_USER="${SUDO_USER:-}"
[[ "$TARGET_USER" == "root" ]] && TARGET_USER=""

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }

# run CMD...: print the command, and run it unless --dry-run.
run() {
  printf '    + %s\n' "$*"
  [[ $DRY_RUN -eq 1 ]] || "$@"
}

# write_file PATH MODE: write stdin to PATH (only if the content changed).
write_file() {
  local path="$1" mode="$2" content
  content="$(cat)"
  printf '    + write %s (mode %s)\n' "$path" "$mode"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s\n' "$content" | sed 's/^/        | /'
    return 0
  fi
  if [[ -f "$path" && "$(cat "$path")" == "$content" ]]; then
    note "unchanged"
  else
    install -d -m 0755 "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
  fi
  chmod "$mode" "$path"
}

export DEBIAN_FRONTEND=noninteractive
[[ $DRY_RUN -eq 1 ]] && note "DRY RUN: nothing will be changed"

# ---------------------------------------------------------------- packages
step "Updating and installing base packages"
run apt-get update
run apt-get -y full-upgrade
run apt-get install -y unattended-upgrades curl git ufw fail2ban rsync ca-certificates jq

step "Enabling unattended security upgrades (non-interactive)"
if [[ $DRY_RUN -eq 1 ]]; then
  note "+ debconf-set-selections (enable_auto_updates=true); dpkg-reconfigure -f noninteractive unattended-upgrades"
else
  echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
  dpkg-reconfigure -f noninteractive unattended-upgrades
fi

# ---------------------------------------------------------------- SSH
step "Hardening SSH"
SSH_OK=0
if [[ -z "$TARGET_USER" ]]; then
  warn "Not run via sudo from a normal user, so I can't check your SSH key. Skipping SSH hardening."
else
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  KEYS="$USER_HOME/.ssh/authorized_keys"
  if [[ -s "$KEYS" ]]; then
    SSH_OK=1
  else
    warn "$KEYS is missing or empty. Skipping SSH hardening so you don't lock yourself out."
    warn "Add your key (ssh-copy-id from your laptop), then re-run this script."
  fi
fi

if [[ $SSH_OK -eq 1 ]]; then
  DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf
  write_file "$DROPIN" 0644 <<'CONF'
# Managed by homelab bootstrap.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
  if [[ $DRY_RUN -eq 1 ]]; then
    note "+ sshd -t && systemctl restart ssh"
  else
    # sshd uses the FIRST value it sees, and files are read in name order, so
    # Ubuntu cloud images' 50-cloud-init.conf (PasswordAuthentication yes)
    # would beat our 99- file. Flip it if present.
    if grep -qsE '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config.d/50-cloud-init.conf; then
      note "50-cloud-init.conf enables password login; changing it to no"
      sed -i -E 's/^(\s*PasswordAuthentication\s+)yes/\1no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    fi
    if sshd -t; then
      if sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
        systemctl restart ssh
        note "ssh restarted. KEEP THIS SESSION OPEN and test a second login before closing it."
      else
        warn "PasswordAuthentication is still on in the effective config. Check: sudo sshd -T | grep -i passwordauth"
      fi
    else
      warn "sshd -t failed, removing $DROPIN and leaving SSH as it was"
      rm -f "$DROPIN"
    fi
  fi
fi

# ---------------------------------------------------------------- firewall
step "Firewall (ufw)"
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow OpenSSH
run ufw --force enable

step "fail2ban (sshd jail)"
JAIL=/etc/fail2ban/jail.local
if [[ -f "$JAIL" ]] && ! grep -q 'Managed by homelab bootstrap' "$JAIL" && [[ $DRY_RUN -eq 0 ]]; then
  warn "$JAIL already exists and isn't ours. Leaving it alone."
else
  write_file "$JAIL" 0644 <<'CONF'
# Managed by homelab bootstrap.sh
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
CONF
fi
run systemctl enable --now fail2ban
run systemctl restart fail2ban

# ---------------------------------------------------------------- Docker
step "Docker (official apt repo)"
if [[ $DRY_RUN -eq 1 ]]; then
  note "+ add download.docker.com apt repo, install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
if [[ -n "$TARGET_USER" ]]; then
  run usermod -aG docker "$TARGET_USER"
  note "$TARGET_USER must log out and in again for the docker group to apply"
else
  warn "No normal user known, not adding anyone to the docker group"
fi

# ---------------------------------------------------------------- Tailscale
step "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  note "already installed"
elif [[ $DRY_RUN -eq 1 ]]; then
  note "+ curl -fsSL https://tailscale.com/install.sh | sh"
else
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# ---------------------------------------------------------------- cloudflared
step "cloudflared (Cloudflare apt repo)"
if [[ $DRY_RUN -eq 1 ]]; then
  note "+ add pkg.cloudflare.com apt repo, install cloudflared"
else
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update
  apt-get install -y cloudflared
fi

# ---------------------------------------------------------------- Ollama
if [[ $SKIP_OLLAMA -eq 1 ]]; then
  step "Ollama: skipped (--skip-ollama)"
else
  step "Ollama (host + Docker containers only, blocked from the LAN by ufw)"
  if command -v ollama >/dev/null 2>&1; then
    note "already installed"
  elif [[ $DRY_RUN -eq 1 ]]; then
    note "+ curl -fsSL https://ollama.com/install.sh | sh"
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  write_file /etc/systemd/system/ollama.service.d/override.conf 0644 <<'CONF'
# Managed by homelab bootstrap.sh.
# Listens on all interfaces so containers (e.g. Open WebUI) can reach it through
# host.docker.internal. ufw (default deny incoming) blocks it from the LAN;
# only Docker's private subnets are allowed in (see the ufw rule below).
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
CONF
  run systemctl daemon-reload
  if [[ $DRY_RUN -eq 1 ]] || systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    run systemctl restart ollama
  fi
  # Let Docker containers (172.16.0.0/12) reach Ollama. Nothing else gets in.
  run ufw allow from 172.16.0.0/12 to any port 11434 proto tcp comment 'Docker to Ollama'
fi

# ---------------------------------------------------------------- secrets dir
step "Secrets directory /etc/homelab"
run install -d -m 0700 -o root -g root /etc/homelab

# ---------------------------------------------------------------- next steps
cat <<NEXT

==> Done$( [[ $DRY_RUN -eq 1 ]] && echo " (dry run, nothing changed)" ).

Manual next steps:
  [ ] Log out and back in (docker group), then: docker run --rm hello-world
  [ ] Test a SECOND ssh login in a new window before closing this one
  [ ] sudo tailscale up --ssh              (open the URL it prints)
  [ ] cloudflared tunnel login && cloudflared tunnel create homelab
      then follow docs/cloudflare-tunnel.md (config, DNS routes, service)
  [ ] ollama pull llama3.1:8b              (skip if you used --skip-ollama)
  [ ] Mount the backup SSD at /mnt/backup  (docs/backups.md)
  [ ] Put the Uptime Kuma push URLs in /etc/homelab/kuma-health-url and
      /etc/homelab/kuma-backup-url (chmod 600)
  [ ] cd docker && docker compose up -d
  [ ] sudo ./scripts/install-cron.sh       (backup + health checks)
  [ ] Optional: once Tailscale works, limit SSH to the tailnet (docs/server-setup.md step 6)
NEXT
