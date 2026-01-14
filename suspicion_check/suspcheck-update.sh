#!/usr/bin/env bash
set -euo pipefail

POLICY_BASE="/usr/lib/suspcheck/policy"
CUR="$POLICY_BASE/current"
BAK="$POLICY_BASE/backup"
MAX_BACKUPS=5

rotate_backups() {
  rm -rf "$BAK/$((MAX_BACKUPS-1))" || true
  for ((i=MAX_BACKUPS-2; i>=0; i--)); do
    [ -d "$BAK/$i" ] && mv "$BAK/$i" "$BAK/$((i+1))"
  done
  mkdir -p "$BAK/0"
  cp -a "$CUR/." "$BAK/0/"
}

fetch_from_db() {
  /usr/lib/suspcheck/bin/suspcheck-engine export-json \
    --out-dir "$CUR.new"
}

main() {
  rotate_backups
  fetch_from_db
  mv "$CUR" "$CUR.old"
  mv "$CUR.new" "$CUR"
  rm -rf "$CUR.old"
}

main "$@"
