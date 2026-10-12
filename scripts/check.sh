#!/usr/bin/env bash
# check.sh - "is everything OK?" after setup, or any time something feels off.
#
#   sudo ./scripts/check.sh [--local]
#
#   --local   skip the public HTTPS checks (use before the tunnel is set up)
#
# Prints [ok], [warn] or [FAIL] per check and exits 1 if anything FAILed.
# Warnings don't change the exit code. Run with sudo so sshd -T, ufw and the
# backup folder can be read; without it some checks will warn or fail.
#
# Settings (environment wins, then /etc/homelab/check.conf as KEY=VALUE lines):
#   DOMAIN         your public domain, e.g. example.com (public checks are
#                  skipped with a warning until this is set)
#   PUBLIC_URLS    extra public URLs to check, space separated
#                  (e.g. "https://app.example.com/healthz")
#   LOCAL_URLS     local URLs to check, space separated
#                  (default: the hub on http://127.0.0.1:9000/)
#   OLLAMA_MODEL   model that should be pulled (default: llama3.1:8b)
set -uo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

load_conf "$HOMELAB_ETC/check.conf" DOMAIN PUBLIC_URLS LOCAL_URLS OLLAMA_MODEL
DOMAIN="${DOMAIN:-}"
PUBLIC_URLS="${PUBLIC_URLS:-}"
LOCAL_URLS="${LOCAL_URLS:-http://127.0.0.1:9000/}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
DISK_WARN=80
DISK_FAIL=90
BACKUP_MAX_HOURS=26
MOUNT=/mnt/backup
load_conf "$HOMELAB_ETC/backup.conf" MOUNT DEST
DEST="${DEST:-$MOUNT/homelab}"

FAILS=0
WARNS=0
ok()   { printf '[ok]   %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
section() { printf '\n%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# http_code URL [extra curl args] -> prints the status code (000 if unreachable)
http_code() {
  local url="$1"
  shift
  curl -s -o /dev/null -m 8 -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}

# check_http LABEL URL
check_http() {
  local code
  code="$(http_code "$2")"
  if [[ "$code" == "200" ]]; then ok "$1 answers 200 ($2)"; else fail "$1 gave ${code:-000} ($2)"; fi
}

section "Services"
for svc in docker tailscaled cloudflared ollama; do
  if ! systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "^$svc.service"; then
    warn "$svc is not installed"
  elif systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "$svc is active"
  else
    fail "$svc is installed but not active (systemctl status $svc)"
  fi
done

section "Security"
if have ufw; then
  UFW="$(ufw status verbose 2>&1)"
  if grep -q "^Status: active" <<<"$UFW"; then
    ok "ufw is active"
    if grep -q "deny (incoming)" <<<"$UFW"; then ok "ufw default is deny incoming"; else fail "ufw default for incoming is not deny"; fi
  else
    fail "ufw is not active (or needs sudo to read)"
  fi
else
  fail "ufw is not installed"
fi

if have sshd; then
  PA="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  case "$PA" in
    no) ok "sshd PasswordAuthentication is no" ;;
    yes) fail "sshd PasswordAuthentication is yes" ;;
    *) warn "could not read sshd config (run with sudo)" ;;
  esac
else
  warn "sshd not installed"
fi

section "Containers"
if have docker && docker info >/dev/null 2>&1; then
  # Every container in the compose project (see "name:" in docker-compose.yml).
  mapfile -t CONTAINERS < <(docker ps -a --filter label=com.docker.compose.project=homelab --format '{{.Names}}' | sort)
  [[ ${#CONTAINERS[@]} -gt 0 ]] || fail "no homelab containers found (cd docker && docker compose up -d)"
  for c in "${CONTAINERS[@]}"; do
    state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || true)"
    if [[ "$state" != "running" ]]; then
      fail "container $c is ${state:-missing}"
    elif [[ -n "$health" && "$health" != "healthy" ]]; then
      fail "container $c is running but $health"
    else
      ok "container $c is running${health:+ ($health)}"
    fi
  done
else
  fail "can't talk to docker (not installed, not running, or not in the docker group)"
fi

section "Local HTTP"
for url in $LOCAL_URLS; do check_http "local" "$url"; done
# Kuma redirects / to /dashboard or /setup, so follow redirects.
code="$(http_code http://127.0.0.1:3001/ -L)"
if [[ "$code" == "200" ]]; then ok "uptime kuma answers 200 (http://127.0.0.1:3001/)"; else fail "uptime kuma gave ${code:-000} (http://127.0.0.1:3001/)"; fi

section "Ollama"
TAGS="$(curl -s -m 8 http://127.0.0.1:11434/api/tags 2>/dev/null || true)"
if [[ -z "$TAGS" ]]; then
  fail "ollama /api/tags did not answer"
elif grep -q "\"$OLLAMA_MODEL\"" <<<"$TAGS"; then
  ok "ollama answers and $OLLAMA_MODEL is pulled"
else
  fail "ollama answers but $OLLAMA_MODEL is not pulled (ollama pull $OLLAMA_MODEL)"
fi

section "Public (via Cloudflare)"
if [[ $LOCAL -eq 1 ]]; then
  warn "skipped (--local)"
elif [[ -z "$DOMAIN" ]]; then
  warn "skipped: set DOMAIN=example.com in $HOMELAB_ETC/check.conf"
else
  check_http "apex" "https://$DOMAIN/"
  check_http "www" "https://www.$DOMAIN/"
  for url in $PUBLIC_URLS; do check_http "public" "$url"; done
  read -r code loc < <(curl -s -o /dev/null -m 8 -w '%{http_code} %{redirect_url}\n' "http://$DOMAIN/" 2>/dev/null || echo "000 -")
  if [[ "$code" =~ ^30[1278]$ && "$loc" == https://* ]]; then
    ok "http://$DOMAIN redirects to https"
  else
    fail "http://$DOMAIN did not redirect to https (got ${code:-000}; turn on Always Use HTTPS in Cloudflare)"
  fi
fi

section "Disk and backups"
for path in / "$MOUNT"; do
  if [[ "$path" == "$MOUNT" ]] && ! mountpoint -q "$MOUNT" 2>/dev/null; then continue; fi
  pct="$(df --output=pcent "$path" 2>/dev/null | tail -n1 | tr -dc '0-9')"
  if [[ -z "$pct" ]]; then
    fail "could not read disk usage for $path"
  elif [[ "$pct" -ge $DISK_FAIL ]]; then
    fail "$path is ${pct}% full"
  elif [[ "$pct" -ge $DISK_WARN ]]; then
    warn "$path is ${pct}% full"
  else
    ok "$path is ${pct}% full"
  fi
done

if mountpoint -q "$MOUNT" 2>/dev/null; then
  ok "$MOUNT is mounted"
  # backup.sh makes DEST/YYYY-MM-DD and points DEST/latest at the newest.
  if [[ -L "$DEST/latest" ]]; then
    snap="$(readlink -f "$DEST/latest")"
    age_h=$(( ( $(date +%s) - $(stat -c %Y "$snap" 2>/dev/null || echo 0) ) / 3600 ))
    if [[ -d "$snap" && $age_h -lt $BACKUP_MAX_HOURS ]]; then
      ok "latest backup is $(basename "$snap"), ${age_h}h old"
    else
      fail "latest backup ($(basename "$snap")) is ${age_h}h old, limit is ${BACKUP_MAX_HOURS}h"
    fi
  else
    fail "no backup yet ($DEST/latest is missing). Try: sudo homelab-backup"
  fi
else
  fail "$MOUNT is not mounted (SSD unplugged?)"
fi

section "Config files"
for f in kuma-health-url kuma-backup-url; do
  if [[ -s "$HOMELAB_ETC/$f" ]]; then ok "$HOMELAB_ETC/$f exists"; else fail "$HOMELAB_ETC/$f is missing or empty (or run with sudo)"; fi
done
if [[ -e /etc/cron.d/homelab ]]; then ok "/etc/cron.d/homelab exists"; else fail "/etc/cron.d/homelab is missing (sudo ./scripts/install-cron.sh)"; fi

section "LAN exposure"
if have ss; then
  # Listening TCP sockets that aren't loopback. Tailscale (100.x) and Docker
  # bridge (172.16-31.x) addresses are fine.
  UNEXPECTED=()
  while read -r addr; do
    host="${addr%:*}"
    host="${host#[}"; host="${host%]}"
    port="${addr##*:}"
    case "$host" in
      127.*|::1) continue ;;
      100.*|fd7a:115c:a1e0*|fe80*) continue ;;
      172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
    esac
    case "$port" in
      22) continue ;;    # ssh, ufw decides who reaches it
      11434) continue ;; # ollama, checked below
      53) continue ;;    # systemd-resolved stub / dhcp client helpers
    esac
    UNEXPECTED+=("$addr")
  done < <(ss -H -ltn 2>/dev/null | awk '{print $4}' | sort -u)
  if [[ ${#UNEXPECTED[@]} -eq 0 ]]; then
    ok "no unexpected listening TCP sockets"
  else
    for a in "${UNEXPECTED[@]}"; do warn "listening on $a (not loopback, tailscale or docker). Intended?"; done
  fi
else
  warn "ss not found, skipping socket check"
fi

if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '^(0\.0\.0\.0|\*|\[::\]):11434$'; then
  if have ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
    RULES="$(ufw status 2>/dev/null | grep -E '(^|[[:space:]])11434')"
    if grep -q "172.16.0.0/12" <<<"$RULES"; then
      ok "ollama is on 0.0.0.0:11434 and ufw allows docker (172.16.0.0/12)"
    else
      fail "ollama is on 0.0.0.0:11434 but there is no ufw rule for 172.16.0.0/12 (containers can't reach it)"
    fi
    if grep -E 'ALLOW' <<<"$RULES" | grep -vq "172.16.0.0/12"; then
      fail "a ufw rule allows 11434 from somewhere other than 172.16.0.0/12"
    else
      ok "no ufw rule opens 11434 to anything else"
    fi
  else
    fail "ollama is on 0.0.0.0:11434 and ufw is not active, so the LAN can reach it"
  fi
fi

printf '\n%d failed, %d warnings\n' "$FAILS" "$WARNS"
[[ $FAILS -eq 0 ]]
