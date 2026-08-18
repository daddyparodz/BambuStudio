#!/usr/bin/env bash
set -euo pipefail

OWNER=""
ARCHIVE=""
APP_NAME="bambustudio-ppa-sync"
DRY_RUN="false"
KEEP_VERSIONS="3"
RESULT_JSON=""
declare -a PACKAGES=()

usage() {
  cat >&2 <<'USAGE'
Usage: prune-ppa.sh --owner <owner> --archive <archive> --package <name> [--package <name> ...] [--keep-versions <count>] [--result-json <path>] [--app-name <name>] [--dry-run]

Keeps the newest N Debian source versions for each package and Ubuntu series,
considering both Published and Superseded Launchpad publications. Older source
publications are explicitly scheduled for deletion, which also removes binaries
built from those sources.

Requires:
  - python3-launchpadlib installed
  - dpkg installed
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
    --keep-versions)
      KEEP_VERSIONS="${2:-}"
      shift 2
      ;;
    --result-json)
      RESULT_JSON="${2:-}"
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
[[ "$KEEP_VERSIONS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --keep-versions value: $KEEP_VERSIONS" >&2; exit 2; }
command -v dpkg >/dev/null 2>&1 || { echo "dpkg is required" >&2; exit 2; }

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
  echo "No Launchpad OAuth credential file found; refusing to skip PPA retention." >&2
  exit 2
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
export PRUNE_KEEP_VERSIONS="$KEEP_VERSIONS"
export PRUNE_RESULT_JSON="$RESULT_JSON"

python3 <<'PY'
import functools
import json
import os
import pathlib
import subprocess
import sys
from collections import defaultdict

from launchpadlib.launchpad import Launchpad


def debian_version_compare(left, right):
    if left == right:
        return 0
    if subprocess.run(
        ["dpkg", "--compare-versions", left, "gt", right],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return 1
    if subprocess.run(
        ["dpkg", "--compare-versions", left, "lt", right],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return -1
    raise RuntimeError(f"Could not compare Debian versions: {left!r} and {right!r}")


def series_name(pub):
    series = getattr(pub, "distro_series", None)
    if series is None:
        return "unknown"
    return str(getattr(series, "name", "") or getattr(series, "self_link", "") or "unknown")


def publication_status(pub):
    return str(getattr(pub, "status", "") or "")


def scheduled_deletion(pub):
    return (
        getattr(pub, "scheduled_deletion_date", None)
        or getattr(pub, "scheduleddeletiondate", None)
    )


owner = os.environ["PRUNE_OWNER"]
archive = os.environ["PRUNE_ARCHIVE"]
packages = [p for p in os.environ["PRUNE_PACKAGES_CSV"].split(",") if p]
app_name = os.environ["PRUNE_APP_NAME"]
dry_run = os.environ["PRUNE_DRY_RUN"] == "true"
keep_versions = int(os.environ["PRUNE_KEEP_VERSIONS"])
result_json = os.environ.get("PRUNE_RESULT_JSON", "")
credentials_file = os.environ["LAUNCHPAD_CREDENTIALS_FILE"]

lp = Launchpad.login_with(
    app_name,
    "production",
    version="devel",
    credentials_file=credentials_file,
)
ppa = lp.people[owner].getPPAByName(name=archive)

status_priority = {"Published": 2, "Superseded": 1}
deleted = 0
already_scheduled = 0
cleanup_pending = 0
excess_publications = 0
retained = {}

for pkg in packages:
    publications = []
    for status in ("Published", "Superseded"):
        publications.extend(
            list(
                ppa.getPublishedSources(
                    source_name=pkg,
                    exact_match=True,
                    status=status,
                    order_by_date=True,
                )
            )
        )

    if not publications:
        print(f"{pkg}: no Published/Superseded sources found")
        retained[pkg] = {}
        continue

    by_series = defaultdict(dict)
    for pub in publications:
        series = series_name(pub)
        version = str(getattr(pub, "source_package_version", "") or "")
        if not version:
            raise RuntimeError(f"{pkg}/{series}: source publication has no version")
        current = by_series[series].get(version)
        if current is None or status_priority.get(publication_status(pub), 0) > status_priority.get(publication_status(current), 0):
            by_series[series][version] = pub

    retained[pkg] = {}
    for series, version_map in sorted(by_series.items()):
        versions = sorted(
            version_map,
            key=functools.cmp_to_key(debian_version_compare),
            reverse=True,
        )
        keep = versions[:keep_versions]
        drop = versions[keep_versions:]
        retained[pkg][series] = keep

        if keep:
            print(f"{pkg}/{series}: keeping newest {len(keep)} version(s): {', '.join(keep)}")
        else:
            print(f"{pkg}/{series}: no versions retained")

        for version in drop:
            pub = version_map[version]
            status = publication_status(pub)
            excess_publications += 1
            cleanup_pending += 1
            scheduled = scheduled_deletion(pub)
            if scheduled:
                already_scheduled += 1
                print(
                    f"{pkg}/{series}: {version} status={status} already scheduled for deletion at {scheduled}"
                )
                continue

            if dry_run:
                print(f"{pkg}/{series}: would delete {version} status={status}")
                continue

            print(f"{pkg}/{series}: deleting {version} status={status}")
            pub.requestDeletion(
                removal_comment=(
                    "Automated PPA retention policy: keep only the newest "
                    f"{keep_versions} source version(s) for {pkg} in Ubuntu {series}."
                )
            )
            deleted += 1

summary = {
    "schema": 1,
    "archive": f"ppa:{owner}/{archive}",
    "keep_versions": keep_versions,
    "packages": packages,
    "dry_run": dry_run,
    "deletion_requests": deleted,
    "already_scheduled": already_scheduled,
    "excess_publications": excess_publications,
    "cleanup_pending": cleanup_pending > 0,
    "retained": retained,
}
print(json.dumps(summary, indent=2, sort_keys=True))
if result_json:
    pathlib.Path(result_json).write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

print(
    f"Done. deletion requests sent: {deleted}; already scheduled: {already_scheduled}; "
    f"cleanup pending: {cleanup_pending > 0}"
)
sys.exit(0)
PY
