#!/usr/bin/env bash
set -euo pipefail

PPA_TARGET="${PPA_TARGET:-ppa:daddyparodz/bambustudio}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-8}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-30}"
MAX_RETRY_DELAY_SECONDS="${MAX_RETRY_DELAY_SECONDS:-300}"
PPA_REVISION="${PPA_REVISION:-1}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source.changes> [<source.changes> ...]" >&2
  exit 1
fi

for changes_file in "$@"; do
  echo "Pre-upload source check for ${changes_file}"
  if (( PPA_REVISION > 1 )); then
    echo "Pre-upload source check: ppa revision > 1, .orig.tar.xz must not be uploaded"
    if grep -qE '\.orig\.tar\.(gz|bz2|xz|lzma)$' "$changes_file"; then
      echo "ERROR: ${changes_file} includes .orig.tar.* but PPA_REVISION=${PPA_REVISION}" >&2
      exit 1
    fi
    echo "OK: .changes excludes .orig.tar.xz"
  fi

  echo "Uploading ${changes_file} to ${PPA_TARGET}..."
  attempt=1
  delay="$RETRY_DELAY_SECONDS"
  while true; do
    upload_log="$(mktemp)"
    if dput "$PPA_TARGET" "$changes_file" 2>&1 | tee "$upload_log"; then
      rm -f "$upload_log"
      break
    fi

    # Retry only on known transient Launchpad/dput transport failures.
    if ! grep -qE '550 Requested action not taken: internal server error|temporary failure|timed out|Connection reset|Network is unreachable' "$upload_log"; then
      echo "Non-retryable upload failure for ${changes_file} on attempt ${attempt}." >&2
      rm -f "$upload_log"
      exit 1
    fi
    rm -f "$upload_log"

    if (( attempt >= UPLOAD_RETRIES )); then
      echo "Upload failed after ${attempt} attempts: ${changes_file}" >&2
      exit 1
    fi

    echo "Upload attempt ${attempt} failed for ${changes_file}; retrying in ${delay}s..." >&2
    sleep "$delay"
    if (( delay < MAX_RETRY_DELAY_SECONDS )); then
      delay=$((delay * 2))
      if (( delay > MAX_RETRY_DELAY_SECONDS )); then
        delay="$MAX_RETRY_DELAY_SECONDS"
      fi
    fi
    attempt=$((attempt + 1))
  done
done
