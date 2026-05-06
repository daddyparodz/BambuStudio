#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/upstream.sh
source "$SCRIPT_DIR/lib/upstream.sh"

CHANNEL="${1:-stable}"
json="$(latest_release_json "$CHANNEL")"

if [[ -z "$json" || "$json" == "null" ]]; then
  exit 1
fi

jq -r '.tag_name' <<<"$json"
