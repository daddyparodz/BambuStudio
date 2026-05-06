#!/usr/bin/env bash
set -euo pipefail

PPA_TARGET="${PPA_TARGET:-ppa:daddyparodz/bambustudio}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-4}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-45}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source.changes> [<source.changes> ...]" >&2
  exit 1
fi

for changes_file in "$@"; do
  echo "Uploading ${changes_file} to ${PPA_TARGET}..."
  attempt=1
  while true; do
    if dput "$PPA_TARGET" "$changes_file"; then
      break
    fi

    if (( attempt >= UPLOAD_RETRIES )); then
      echo "Upload failed after ${attempt} attempts: ${changes_file}" >&2
      exit 1
    fi

    echo "Upload attempt ${attempt} failed for ${changes_file}; retrying in ${RETRY_DELAY_SECONDS}s..." >&2
    sleep "$RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
done
