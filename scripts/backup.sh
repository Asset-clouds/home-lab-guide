#!/usr/bin/env bash
# backup.sh - snapshot-style backup to the external SSD using rsync --link-dest.
#
#   sudo ./scripts/backup.sh [--dry-run]
#
# Each run creates DEST/YYYY-MM-DD. Files that haven't changed since the previous
# snapshot are hard-linked, so snapshots look full but only cost the changes.
# DEST/latest points at the newest one. The newest KEEP_DAYS snapshots are kept.
# The SSD must be ext4 (or similar) for hard links and permissions to work.
#
# Settings (environment wins, then /etc/homelab/backup.conf as KEY=VALUE lines):
#   BACKUP_USER      user whose ~/homelab is backed up (default: $SUDO_USER)
#   REPO_NAME        repo folder name in that home (default: homelab)
#   MOUNT            backup SSD mount point (default: /mnt/backup)
#   DEST             snapshot root (default: $MOUNT/homelab)
#   KEEP_DAYS        snapshots to keep (default: 14)
#   STOP_FOR_BACKUP  1 = briefly stop STOP_CONTAINERS around the copy
#   STOP_CONTAINERS  compose services to stop, space separated (e.g. "myapp")
#
# Caveats:
# * SQLite is copied LIVE by default. A write during the copy could give a
#   slightly inconsistent copy of an app's database. Fine for a low-traffic
#   hobby site; set STOP_FOR_BACKUP=1 and STOP_CONTAINERS for a clean copy
#   (a few seconds of downtime at 2am).
# * Ollama models (~/.ollama, /usr/share/ollama) are NOT backed up: they're
#   several GB and can be re-downloaded with `ollama pull llama3.1:8b`.
# * Same room as the server, so not an offsite backup (see docs/backups.md).
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0 $*" >&2
  exit 1
fi

load_conf "$HOMELAB_ETC/backup.conf" BACKUP_USER REPO_NAME MOUNT DEST KEEP_DAYS STOP_FOR_BACKUP STOP_CONTAINERS
BACKUP_USER="${BACKUP_USER:-${SUDO_USER:-}}"
REPO_NAME="${REPO_NAME:-homelab}"
MOUNT="${MOUNT:-/mnt/backup}"
DEST="${DEST:-$MOUNT/homelab}"
KEEP_DAYS="${KEEP_DAYS:-14}"
STOP_FOR_BACKUP="${STOP_FOR_BACKUP:-0}"
STOP_CONTAINERS="${STOP_CONTAINERS:-}"
LOG=/var/log/homelab-backup.log
KUMA_FILE="$HOMELAB_ETC/kuma-backup-url"

# Log to the file and to the terminal.
exec > >(tee -a "$LOG") 2>&1
log() { printf '%s %s\n' "$(date -Is)" "$*"; }

STOPPED=()
COMPOSE_FILE=""

cleanup() {
  local rc=$?
  trap - EXIT
  # Never leave a container stopped.
  if [[ ${#STOPPED[@]} -gt 0 ]]; then
    log "restarting ${STOPPED[*]}"
    docker compose -f "$COMPOSE_FILE" start "${STOPPED[@]}" || log "WARNING: could not restart ${STOPPED[*]}!"
  fi
  if [[ $rc -ne 0 ]]; then
    log "backup FAILED (exit $rc)"
    [[ $DRY_RUN -eq 1 ]] || kuma_ping "$KUMA_FILE" down "backup failed (exit $rc)"
  fi
  exit "$rc"
}
trap cleanup EXIT

if [[ $DRY_RUN -eq 1 ]]; then log "backup starting (dry run)"; else log "backup starting"; fi

if ! mountpoint -q "$MOUNT"; then
  log "$MOUNT is not a mountpoint (SSD not plugged in or not mounted). Refusing to run."
  exit 1
fi
[[ "$KEEP_DAYS" =~ ^[0-9]+$ && "$KEEP_DAYS" -ge 1 ]] || { log "KEEP_DAYS must be a positive number"; exit 1; }

# ---- sources (absolute paths; missing ones are skipped with a note)
SOURCES=()
add_source() {
  if [[ -e "$1" ]]; then SOURCES+=("$1"); else log "skipping $1 (not found)"; fi
}
if [[ -n "$BACKUP_USER" && "$BACKUP_USER" != "root" ]]; then
  USER_HOME="$(getent passwd "$BACKUP_USER" | cut -d: -f6)"
  if [[ -n "$USER_HOME" ]]; then
    add_source "$USER_HOME/$REPO_NAME"
    COMPOSE_FILE="$USER_HOME/$REPO_NAME/docker/docker-compose.yml"
  else
    log "WARNING: user '$BACKUP_USER' not found, skipping the repo"
  fi
else
  log "WARNING: BACKUP_USER not set (put BACKUP_USER=yourname in $HOMELAB_ETC/backup.conf), skipping the repo"
fi
add_source /etc/cloudflared
add_source /etc/homelab
add_source /var/lib/docker/volumes

if [[ ${#SOURCES[@]} -eq 0 ]]; then log "nothing to back up"; exit 1; fi

# ---- work out names
TODAY="$(date +%F)"
SNAP="$DEST/$TODAY"
PARTIAL="$DEST/.partial-$TODAY"
[[ $DRY_RUN -eq 1 ]] || mkdir -p "$DEST"

# Previous snapshot to hard-link against: newest dated dir that isn't today.
PREV=""
while IFS= read -r d; do
  if [[ "$d" != "$TODAY" ]]; then PREV="$DEST/$d"; break; fi
done < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
           -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' -printf '%f\n' | sort -r)

RSYNC_OPTS=(-aHAXR --numeric-ids --delete --delete-excluded
  --exclude '.ollama' --exclude '__pycache__' --exclude '.venv')
[[ -z "$PREV" ]] || RSYNC_OPTS+=("--link-dest=$PREV")
[[ $DRY_RUN -eq 0 ]] || RSYNC_OPTS+=(-n --itemize-changes)

log "sources: ${SOURCES[*]}"
log "snapshot: $SNAP (previous: ${PREV:-none})"

if [[ "$STOP_FOR_BACKUP" == "1" && $DRY_RUN -eq 0 ]]; then
  for c in $STOP_CONTAINERS; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then STOPPED+=("$c"); fi
  done
  if [[ ${#STOPPED[@]} -gt 0 ]]; then
    log "STOP_FOR_BACKUP=1: stopping ${STOPPED[*]}"
    docker compose -f "$COMPOSE_FILE" stop "${STOPPED[@]}"
  fi
fi

# rsync exit 24 = files vanished mid-copy (normal for live Docker volumes).
rc=0
rsync "${RSYNC_OPTS[@]}" "${SOURCES[@]}" "$PARTIAL/" || rc=$?
if [[ $rc -ne 0 && $rc -ne 24 ]]; then
  log "rsync failed with exit $rc"
  exit "$rc"
fi
[[ $rc -ne 24 ]] || log "note: some files vanished during the copy (normal for live volumes)"

if [[ ${#STOPPED[@]} -gt 0 ]]; then
  log "restarting ${STOPPED[*]}"
  docker compose -f "$COMPOSE_FILE" start "${STOPPED[@]}"
  STOPPED=()
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "dry run finished. Nothing was written, kept or deleted."
  exit 0
fi

# ---- publish the snapshot: swap partial into place, update latest
if [[ -d "$SNAP" ]]; then mv "$SNAP" "$DEST/.old-$TODAY"; fi
mv "$PARTIAL" "$SNAP"
rm -rf "${DEST:?}/.old-$TODAY"
ln -sfn "$TODAY" "$DEST/latest"

# ---- retention: keep the newest KEEP_DAYS dated snapshots
mapfile -t OLD < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
                     -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' -printf '%f\n' | sort -r | tail -n +"$((KEEP_DAYS + 1))")
for d in "${OLD[@]}"; do
  log "pruning old snapshot $d"
  rm -rf "${DEST:?}/$d"
done

USED="$(df -h --output=pcent "$MOUNT" | tail -1 | tr -d ' ')"
log "backup finished OK ($SNAP, SSD $USED full)"
kuma_ping "$KUMA_FILE" up "backup ok $TODAY, SSD $USED full"
