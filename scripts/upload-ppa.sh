#!/usr/bin/env bash
set -euo pipefail

PPA_TARGET="${PPA_TARGET:-ppa:daddyparodz/bambustudio}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-8}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-30}"
MAX_RETRY_DELAY_SECONDS="${MAX_RETRY_DELAY_SECONDS:-300}"
DPUT_TIMEOUT_SECONDS="${DPUT_TIMEOUT_SECONDS:-240}"
PPA_REVISION="${PPA_REVISION:-1}"
SOURCE_INCLUDE_MODE="${SOURCE_INCLUDE_MODE:-auto}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source.changes> [<source.changes> ...]" >&2
  exit 1
fi

for changes_file in "$@"; do
  echo "Pre-upload source check for ${changes_file}"
  has_orig=false
  if grep -qE '\.orig\.tar\.(gz|bz2|xz|lzma)$' "$changes_file"; then
    has_orig=true
  fi

  if [[ "$SOURCE_INCLUDE_MODE" == "exclude-orig" ]]; then
    if [[ "$has_orig" == "true" ]]; then
      echo "ERROR: ${changes_file} includes .orig.tar.* but SOURCE_INCLUDE_MODE=exclude-orig" >&2
      exit 1
    fi
  elif [[ "$SOURCE_INCLUDE_MODE" == "auto" ]]; then
    # Auto mode is intentionally permissive here. Build-time logic already
    # chooses include/exclude orig based on availability, and Launchpad is the
    # source of truth if remote state changes between build and upload.
    :
  fi

  if [[ "$has_orig" == "true" ]]; then
    echo "Pre-upload source check: .changes includes orig tarball"
  else
    echo "Pre-upload source check: .changes excludes orig tarball"
  fi

  echo "Uploading ${changes_file} to ${PPA_TARGET}..."
  attempt=1
  delay="$RETRY_DELAY_SECONDS"
  while true; do
    upload_log="$(mktemp)"
    dput_rc=0
    if timeout --preserve-status "$DPUT_TIMEOUT_SECONDS" dput "$PPA_TARGET" "$changes_file" 2>&1 | tee "$upload_log"; then
      rm -f "$upload_log"
      break
    else
      dput_rc=$?
    fi

    # Retry only on known transient Launchpad/dput transport failures.
    if (( dput_rc == 124 || dput_rc == 137 )); then
      echo "dput timed out after ${DPUT_TIMEOUT_SECONDS}s (attempt ${attempt})" >&2
    elif ! grep -qE '550 Requested action not taken: internal server error|temporary failure|timed out|Connection reset|Network is unreachable|Connection timed out|Could not connect|TLS handshake|EOF' "$upload_log"; then
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
