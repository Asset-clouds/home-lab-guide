#!/usr/bin/env bash
# restore.sh - list backup snapshots and restore a path from one.
#
#   ./scripts/restore.sh list
#   ./scripts/restore.sh SNAPSHOT PATH [--target DIR] [--in-place]
#
#   SNAPSHOT   a date like 2026-10-12, or "latest"
#   PATH       the ORIGINAL absolute path, e.g. /etc/cloudflared or
#              /home/YOUR_USER/homelab/docker/docker-compose.yml
#   --target   where to restore to (default /tmp/restore-<date>)
#   --in-place restore over the live files. Asks for confirmation, shows what
#              would change first, and keeps overwritten files as *.pre-restore-*
#
# By default nothing live is touched: files are copied to a staging folder and
# you copy back what you need. Needs root to read root-owned files.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

load_conf "$HOMELAB_ETC/backup.conf" MOUNT DEST
MOUNT="${MOUNT:-/mnt/backup}"
DEST="${DEST:-$MOUNT/homelab}"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

[[ $# -ge 1 ]] || { usage; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

mountpoint -q "$MOUNT" || { echo "$MOUNT is not mounted. Plug in / mount the backup SSD first." >&2; exit 1; }
[[ -d "$DEST" ]] || { echo "No backups found in $DEST" >&2; exit 1; }

if [[ "$1" == "list" ]]; then
  latest="$(readlink "$DEST/latest" 2>/dev/null || true)"
  echo "Snapshots in $DEST:"
  find "$DEST" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
    -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' -printf '%f\n' | sort -r |
    while IFS= read -r d; do
      if [[ "$d" == "$latest" ]]; then echo "  $d  (latest)"; else echo "  $d"; fi
    done
  exit 0
fi

SNAPSHOT="$1"
[[ $# -ge 2 ]] || { usage; exit 2; }
SRC_PATH="$2"
shift 2

TARGET="/tmp/restore-$(date +%F)"
IN_PLACE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place) IN_PLACE=1 ;;
    --target) shift; TARGET="${1:?--target needs a directory}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$SNAPSHOT" == "latest" || "$SNAPSHOT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "Bad snapshot name: $SNAPSHOT" >&2; exit 2; }
[[ "$SRC_PATH" == /* ]] || { echo "PATH must be absolute (the original location), e.g. /etc/cloudflared" >&2; exit 2; }
[[ "$SRC_PATH" != *..* ]] || { echo "PATH must not contain .." >&2; exit 2; }

REL="${SRC_PATH#/}"
SNAP_ROOT="$(readlink -f "$DEST/$SNAPSHOT")"
[[ -e "$SNAP_ROOT/$REL" ]] || { echo "Not in snapshot $SNAPSHOT: $SRC_PATH" >&2; echo "Run '$0 list' to see snapshots." >&2; exit 1; }

# The "/./" marks where rsync -R starts recreating the path.
if [[ $IN_PLACE -eq 1 ]]; then
  [[ $EUID -eq 0 ]] || { echo "--in-place needs root (sudo)." >&2; exit 1; }
  SUFFIX=".pre-restore-$(date +%F-%H%M%S)"
  echo "Would change these live files (dry run):"
  rsync -aHAXR -n --itemize-changes --backup --suffix="$SUFFIX" "$SNAP_ROOT/./$REL" / || true
  echo
  echo "This will OVERWRITE live files under $SRC_PATH with the copy from $SNAPSHOT."
  echo "Overwritten files are kept next to the originals with the suffix $SUFFIX."
  echo "Stop any container using these files first."
  read -r -p "Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 1; }
  rsync -aHAXR --backup --suffix="$SUFFIX" "$SNAP_ROOT/./$REL" /
  echo "Restored $SRC_PATH in place."
else
  mkdir -p "$TARGET"
  rsync -aHAXR "$SNAP_ROOT/./$REL" "$TARGET/"
  echo "Restored to $TARGET/$REL (live files untouched)."
fi
