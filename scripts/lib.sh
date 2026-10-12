#!/usr/bin/env bash
# Shared helpers for the homelab scripts. Sourced, not run directly.

# shellcheck disable=SC2034  # used by the scripts that source this file
HOMELAB_ETC="/etc/homelab"

# load_conf FILE KEY...
# Reads simple KEY=VALUE lines from FILE for the listed keys only. A variable
# that is already set in the environment wins over the file. The file is parsed,
# not sourced, so it can't run commands.
load_conf() {
  local file="$1" key line k v
  shift
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    k="${k//[[:space:]]/}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    for key in "$@"; do
      if [[ "$k" == "$key" && -z "${!k+x}" ]]; then
        printf -v "$k" '%s' "$v"
        # shellcheck disable=SC2163  # exporting by name is intended
        export "$k"
      fi
    done
  done < "$file"
}

# kuma_ping URL_FILE STATUS MESSAGE
# Pushes to an Uptime Kuma push monitor. The file holds the push URL (anything
# after a "?" is ignored). Never fails the caller: monitoring must not break jobs.
kuma_ping() {
  local file="$1" status="$2" msg="$3" url
  [[ -r "$file" ]] || return 0
  url="$(head -n1 "$file" | tr -d '[:space:]')"
  url="${url%%\?*}"
  [[ -n "$url" ]] || return 0
  curl -fsS -m 10 -G --data-urlencode "status=${status}" --data-urlencode "msg=${msg}" \
    "$url" >/dev/null 2>&1 || echo "warning: could not reach Uptime Kuma at $file" >&2
  return 0
}
