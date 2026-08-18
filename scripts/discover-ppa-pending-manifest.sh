#!/usr/bin/env bash
set -euo pipefail

PACKAGE=""
CHANNEL=""
TAG=""
COMMIT=""
REVISION=""
SERIES=""
OWNER="${PPA_OWNER:-daddyparodz}"
ARCHIVE="${PPA_ARCHIVE:-bambustudio}"
CREATED_AT="${PPA_PENDING_CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

usage() {
  cat >&2 <<'USAGE'
Usage: discover-ppa-pending-manifest.sh \
  --package NAME --channel CHANNEL --tag TAG --commit SHA --revision N \
  --series "jammy noble"

Discovers an already accepted active Launchpad revision and prints a pending
JSON manifest. This is used to recover state after an upload succeeded but
release bookkeeping was not recorded. Only Pending or Published sources are
eligible for recovery; inactive history must be superseded by a new revision.
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) PACKAGE="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --series) SERIES="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$PACKAGE" ]] || usage
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || { echo "Invalid channel: $CHANNEL" >&2; exit 2; }
[[ -n "$TAG" ]] || usage
[[ "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "Invalid commit: $COMMIT" >&2; exit 2; }
[[ "$REVISION" =~ ^[0-9]+$ ]] || { echo "Invalid revision: $REVISION" >&2; exit 2; }
[[ -n "$SERIES" ]] || usage

export PPA_DISCOVER_PACKAGE="$PACKAGE"
export PPA_DISCOVER_CHANNEL="$CHANNEL"
export PPA_DISCOVER_TAG="$TAG"
export PPA_DISCOVER_COMMIT="$COMMIT"
export PPA_DISCOVER_REVISION="$REVISION"
export PPA_DISCOVER_SERIES="$SERIES"
export PPA_DISCOVER_OWNER="$OWNER"
export PPA_DISCOVER_ARCHIVE="$ARCHIVE"
export PPA_DISCOVER_CREATED_AT="$CREATED_AT"

python3 - <<'PY'
import json
import os
import re

from launchpadlib.launchpad import Launchpad

package = os.environ["PPA_DISCOVER_PACKAGE"]
channel = os.environ["PPA_DISCOVER_CHANNEL"]
tag = os.environ["PPA_DISCOVER_TAG"]
commit = os.environ["PPA_DISCOVER_COMMIT"]
revision = int(os.environ["PPA_DISCOVER_REVISION"])
series_list = os.environ["PPA_DISCOVER_SERIES"].split()
owner = os.environ["PPA_DISCOVER_OWNER"]
archive_name = os.environ["PPA_DISCOVER_ARCHIVE"]
upstream = tag[1:] if tag.startswith("v") else tag
rx = re.compile(rf"^{re.escape(upstream)}\+.+-0ppa{revision}~")

lp = Launchpad.login_anonymously(
    "bambustudio-ppa-state-recovery",
    "production",
    version="devel",
)
ppa = lp.people[owner].getPPAByName(name=archive_name)
ubuntu = lp.distributions["ubuntu"]

sources = []
for series in series_list:
    distro_series = ubuntu.getSeries(name_or_version=series)
    matches = {}
    for status in ("Pending", "Published"):
        pubs = ppa.getPublishedSources(
            source_name=package,
            exact_match=True,
            distro_series=distro_series,
            status=status,
            order_by_date=True,
        )
        for pub in pubs:
            version = str(pub.source_package_version)
            if rx.match(version):
                matches[version] = status
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one active Launchpad source for {package} {series} "
            f"revision ppa{revision}, found {matches}"
        )
    version = next(iter(matches))
    sources.append({"series": series, "version": version})

manifest = {
    "schema": 1,
    "status": "pending",
    "channel": channel,
    "package": package,
    "tag": tag,
    "commit": commit,
    "revision": revision,
    "created_at": os.environ["PPA_DISCOVER_CREATED_AT"],
    "recovered": True,
    "sources": sources,
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY
