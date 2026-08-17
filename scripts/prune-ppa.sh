#!/usr/bin/env bash
set -euo pipefail

OWNER=""
ARCHIVE=""
APP_NAME="bambustudio-ppa-sync"
DRY_RUN="false"
declare -a PACKAGES=()

usage() {
  cat >&2 <<'USAGE'
Usage: prune-ppa.sh --owner <owner> --archive <archive> --package <name> [--package <name> ...] [--app-name <name>] [--dry-run]

Requires:
  - python3-launchpadlib installed
  - Launchpad OAuth credentials available from one of:
    0) LAUNCHPAD_CREDENTIALS (raw credential text)
    1) LAUNCHPAD_CREDENTIALS_FILE
    2) LAUNCHPAD_OAUTH_CREDENTIALS_FILE
    3) common local credential paths (including /home/dak/bambustudio-launchpad-safe-keep)
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    --archive)
      ARCHIVE="${2:-}"
      shift 2
      ;;
    --package)
      PACKAGES+=("${2:-}")
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$OWNER" ]] || usage
[[ -n "$ARCHIVE" ]] || usage
(( ${#PACKAGES[@]} > 0 )) || usage

resolve_credentials_file() {
  if [[ -n "${LAUNCHPAD_CREDENTIALS:-}" ]]; then
    local tmp_cred
    tmp_cred="$(mktemp)"
    chmod 600 "$tmp_cred"
    printf '%s\n' "$LAUNCHPAD_CREDENTIALS" > "$tmp_cred"
    export PRUNE_TEMP_CREDENTIALS_FILE="$tmp_cred"
    printf '%s\n' "$tmp_cred"
    return 0
  fi

  if [[ -n "${LAUNCHPAD_CREDENTIALS_FILE:-}" ]]; then
    printf '%s\n' "$LAUNCHPAD_CREDENTIALS_FILE"
    return 0
  fi
  if [[ -n "${LAUNCHPAD_OAUTH_CREDENTIALS_FILE:-}" ]]; then
    printf '%s\n' "$LAUNCHPAD_OAUTH_CREDENTIALS_FILE"
    return 0
  fi

  local candidate
  for candidate in \
    "/home/dak/bambustudio-launchpad-safe-keep/launchpad.credentials" \
    "/home/dak/bambustudio-launchpad-safe-keep/LAUNCHPAD_OAUTH_CREDENTIALS" \
    "/home/dak/bambustudio-launchpad-safe-keep/LAUNCHPAD_OAUTH_CREDENTIALS.txt" \
    "${HOME}/.cache/launchpadlib/credentials"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if credentials_file="$(resolve_credentials_file)"; then
  if [[ ! -f "$credentials_file" ]]; then
    echo "Credential file does not exist: $credentials_file" >&2
    exit 2
  fi
  export LAUNCHPAD_CREDENTIALS_FILE="$credentials_file"
else
  echo "No Launchpad OAuth credential file found; skipping PPA pruning." >&2
  exit 0
fi

cleanup() {
  if [[ -n "${PRUNE_TEMP_CREDENTIALS_FILE:-}" && -f "${PRUNE_TEMP_CREDENTIALS_FILE}" ]]; then
    rm -f "${PRUNE_TEMP_CREDENTIALS_FILE}"
  fi
}
trap cleanup EXIT

packages_csv=""
for pkg in "${PACKAGES[@]}"; do
  if [[ -z "$packages_csv" ]]; then
    packages_csv="$pkg"
  else
    packages_csv="$packages_csv,$pkg"
  fi
done

export PRUNE_OWNER="$OWNER"
export PRUNE_ARCHIVE="$ARCHIVE"
export PRUNE_PACKAGES_CSV="$packages_csv"
export PRUNE_APP_NAME="$APP_NAME"
export PRUNE_DRY_RUN="$DRY_RUN"

python3 <<'PY'
import os
import sys
from collections import defaultdict

from launchpadlib.launchpad import Launchpad


def publication_sort_key(pub):
    return (
        str(getattr(pub, "date_published", "") or ""),
        str(getattr(pub, "date_created", "") or ""),
        str(getattr(pub, "self_link", "") or ""),
    )


def series_name(pub):
    series = getattr(pub, "distro_series", None)
    if series is None:
        return "unknown"
    return str(getattr(series, "name", "") or getattr(series, "self_link", "") or "unknown")


owner = os.environ["PRUNE_OWNER"]
archive = os.environ["PRUNE_ARCHIVE"]
packages = [p for p in os.environ["PRUNE_PACKAGES_CSV"].split(",") if p]
app_name = os.environ["PRUNE_APP_NAME"]
dry_run = os.environ["PRUNE_DRY_RUN"] == "true"
credentials_file = os.environ["LAUNCHPAD_CREDENTIALS_FILE"]

lp = Launchpad.login_with(
    app_name,
    "production",
    version="devel",
    credentials_file=credentials_file,
)
ppa = lp.people[owner].getPPAByName(name=archive)

deleted = 0
for pkg in packages:
    pubs = list(
        ppa.getPublishedSources(
            source_name=pkg,
            exact_match=True,
            status="Published",
            order_by_date=True,
        )
    )

    if not pubs:
        print(f"{pkg}: no published sources found")
        continue

    by_series = defaultdict(list)
    for pub in pubs:
        by_series[series_name(pub)].append(pub)

    for series, series_pubs in sorted(by_series.items()):
        series_pubs.sort(key=publication_sort_key, reverse=True)
        keep = series_pubs[0]
        keep_version = getattr(keep, "source_package_version", "<unknown>")
        print(f"{pkg}/{series}: keeping {keep_version}")

        for old in series_pubs[1:]:
            old_version = getattr(old, "source_package_version", "<unknown>")
            print(f"{pkg}/{series}: deleting {old_version}")
            if not dry_run:
                old.requestDeletion(
                    removal_comment=(
                        "Automated PPA retention policy: keep only the latest "
                        f"published source for {pkg} in Ubuntu {series}."
                    )
                )
            deleted += 1

print(f"Done. deletion requests sent: {deleted}")
sys.exit(0)
PY
