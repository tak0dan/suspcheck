#!/usr/bin/env bash
set -euo pipefail

ENGINE="/usr/lib/suspcheck/bin/suspcheck-engine"
POLICY_DIR="/usr/lib/suspcheck/policy/current"

case "$1" in
  evaluate)
    shift
    exec "$ENGINE" \
      --policy-dir "$POLICY_DIR" \
      evaluate "$@"
    ;;
  update)
    exec /usr/lib/suspcheck/bin/suspcheck-update
    ;;
  *)
    echo "Usage: suspcheck {evaluate|update}"
    exit 1
    ;;
esac
