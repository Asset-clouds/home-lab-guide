#!/usr/bin/env bash
# health.sh - checks CPU, disk, memory and key services, then reports to an
# Uptime Kuma Push monitor. Run from cron every 5 minutes (see install-cron.sh).
#
# The push URL lives in /etc/homelab/kuma-health-url (one line, chmod 600).
# Without that file this prints a message and exits 0.
#
# Thresholds can be overridden from the environment:
#   CPU_MAX   load as % of cores (5 min average)   default 90
#   DISK_MAX  % used on /                           default 85
#   MEM_MAX   % of memory in use                    default 90
#   SERVICES  services that must be active          default: cloudflared tailscaled docker
# ollama is also checked, but only if it is installed.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

URL_FILE="$HOMELAB_ETC/kuma-health-url"
CPU_MAX="${CPU_MAX:-90}"
DISK_MAX="${DISK_MAX:-85}"
MEM_MAX="${MEM_MAX:-90}"
SERVICES="${SERVICES:-cloudflared tailscaled docker}"

if [[ ! -r "$URL_FILE" ]]; then
  echo "health.sh: $URL_FILE not found or not readable (run as root). Nothing to report to."
  exit 0
fi

problems=()

# CPU: 5-minute load average as a percentage of cores (the 1-minute figure is
# too jumpy for a 5-minute check).
cores="$(nproc)"
load="$(awk '{print $2}' /proc/loadavg)"
cpu="$(awk -v l="$load" -v c="$cores" 'BEGIN{printf "%d", l/c*100}')"
[[ "$cpu" -le "$CPU_MAX" ]] || problems+=("cpu ${cpu}%")

# Disk: root filesystem.
disk="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
[[ "$disk" -le "$DISK_MAX" ]] || problems+=("disk ${disk}%")

# Memory: used = total - available.
mem="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)/t*100}' /proc/meminfo)"
[[ "$mem" -le "$MEM_MAX" ]] || problems+=("mem ${mem}%")

# Services.
read -r -a services <<< "$SERVICES"
if systemctl list-unit-files ollama.service 2>/dev/null | grep -q '^ollama.service'; then
  services+=(ollama)
fi
for svc in "${services[@]}"; do
  systemctl is-active --quiet "$svc" || problems+=("$svc not active")
done

summary="cpu ${cpu}% disk ${disk}% mem ${mem}%"
if [[ ${#problems[@]} -eq 0 ]]; then
  status=up
  msg="OK: $summary"
else
  status=down
  msg="PROBLEM: $(IFS=,; echo "${problems[*]}") ($summary)"
fi

[[ -t 1 ]] && echo "$status: $msg"
kuma_ping "$URL_FILE" "$status" "$msg"
