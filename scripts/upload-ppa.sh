#!/usr/bin/env bash
set -euo pipefail

PPA_TARGET="${PPA_TARGET:-ppa:daddyparodz/bambustudio}"
PPA_UPLOAD_METHOD="${PPA_UPLOAD_METHOD:-auto}"
LAUNCHPAD_SFTP_LOGIN="${LAUNCHPAD_SFTP_LOGIN:-}"
LAUNCHPAD_SSH_PRIVATE_KEY="${LAUNCHPAD_SSH_PRIVATE_KEY:-}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-8}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-30}"
MAX_RETRY_DELAY_SECONDS="${MAX_RETRY_DELAY_SECONDS:-300}"
DPUT_TIMEOUT_SECONDS="${DPUT_TIMEOUT_SECONDS:-1200}"
PPA_REVISION="${PPA_REVISION:-1}"
SOURCE_INCLUDE_MODE="${SOURCE_INCLUDE_MODE:-auto}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source.changes> [<source.changes> ...]" >&2
  exit 1
fi

setup_sftp_target() {
  local target="$1"
  if [[ ! "$target" =~ ^ppa:([^/]+)/([^/]+)$ ]]; then
    echo "SFTP mode requires PPA_TARGET in ppa:<owner>/<archive> format (got: $target)" >&2
    return 1
  fi
  local owner="${BASH_REMATCH[1]}"
  local archive="${BASH_REMATCH[2]}"
  local login="$LAUNCHPAD_SFTP_LOGIN"
  if [[ -z "$login" ]]; then
    login="$owner"
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  printf '%s\n' "$LAUNCHPAD_SSH_PRIVATE_KEY" > "$HOME/.ssh/id_launchpad_upload"
  chmod 600 "$HOME/.ssh/id_launchpad_upload"
  cat > "$HOME/.ssh/config" <<EOF
Host ppa.launchpad.net
  User ${login}
  IdentityFile ~/.ssh/id_launchpad_upload
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  chmod 600 "$HOME/.ssh/config"
  ssh-keyscan -H ppa.launchpad.net >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  chmod 600 "$HOME/.ssh/known_hosts"

  cat > "$HOME/.dput.cf" <<EOF
[launchpad-sftp]
fqdn = ppa.launchpad.net
method = sftp
incoming = ~${owner}/ubuntu/${archive}/
login = ${login}
allow_unsigned_uploads = 0
EOF
}

upload_target="$PPA_TARGET"
case "$PPA_UPLOAD_METHOD" in
  auto)
    if [[ -n "$LAUNCHPAD_SSH_PRIVATE_KEY" ]]; then
      setup_sftp_target "$PPA_TARGET"
      upload_target="launchpad-sftp"
      echo "Upload transport: sftp (auto-selected)"
    else
      echo "Upload transport: ftp (auto-selected)"
    fi
    ;;
  sftp)
    if [[ -z "$LAUNCHPAD_SSH_PRIVATE_KEY" ]]; then
      echo "PPA_UPLOAD_METHOD=sftp but LAUNCHPAD_SSH_PRIVATE_KEY is not set" >&2
      exit 1
    fi
    setup_sftp_target "$PPA_TARGET"
    upload_target="launchpad-sftp"
    echo "Upload transport: sftp (forced)"
    ;;
  ftp)
    echo "Upload transport: ftp (forced)"
    ;;
  *)
    echo "Unsupported PPA_UPLOAD_METHOD: $PPA_UPLOAD_METHOD" >&2
    exit 1
    ;;
esac

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

  echo "Uploading ${changes_file} to ${upload_target}..."
  perform_upload() {
    local target="$1"
    local attempt=1
    local delay="$RETRY_DELAY_SECONDS"
    while true; do
      upload_log="$(mktemp)"
      dput_rc=0
      if timeout --preserve-status "$DPUT_TIMEOUT_SECONDS" dput "$target" "$changes_file" 2>&1 | tee "$upload_log"; then
        rm -f "$upload_log"
        return 0
      else
        dput_rc=$?
      fi

      # timeout with --preserve-status may return 124, or child signal exit (>=128).
      if (( dput_rc == 124 || dput_rc >= 128 )); then
        echo "dput timed out/terminated after ${DPUT_TIMEOUT_SECONDS}s (attempt ${attempt}, rc=${dput_rc})" >&2
      elif ! grep -qE '550 Requested action not taken: internal server error|temporary failure|timed out|Connection reset|Network is unreachable|Connection timed out|Could not connect|TLS handshake|EOF|Broken pipe|Connection closed|Failure writing network stream' "$upload_log"; then
        echo "Non-retryable upload failure for ${changes_file} on attempt ${attempt} (target=${target})." >&2
        rm -f "$upload_log"
        return 1
      fi
      rm -f "$upload_log"

      if (( attempt >= UPLOAD_RETRIES )); then
        echo "Upload failed after ${attempt} attempts: ${changes_file} (target=${target})" >&2
        return 2
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
  }

  if perform_upload "$upload_target"; then
    :
  elif [[ "$upload_target" == "launchpad-sftp" && "$PPA_UPLOAD_METHOD" == "auto" ]]; then
    echo "SFTP upload exhausted retries; falling back to ftp target ${PPA_TARGET}." >&2
    perform_upload "$PPA_TARGET"
  else
    exit 1
  fi
done
