#!/usr/bin/env bash
set -euo pipefail

PPA_TARGET="${PPA_TARGET:-ppa:daddyparodz/bambustudio}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source.changes> [<source.changes> ...]" >&2
  exit 1
fi

for changes_file in "$@"; do
  echo "Uploading ${changes_file} to ${PPA_TARGET}..."
  dput "$PPA_TARGET" "$changes_file"
done
