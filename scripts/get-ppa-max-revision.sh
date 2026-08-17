#!/usr/bin/env bash
set -euo pipefail

PACKAGE=""
UPSTREAM_VERSION=""
SERIES=""
OWNER="${PPA_OWNER:-daddyparodz}"
ARCHIVE="${PPA_ARCHIVE:-bambustudio}"

usage() {
  cat >&2 <<'EOF'
Usage: get-ppa-max-revision.sh --package NAME --upstream-version VERSION --series "jammy noble"

Prints the highest historical 0ppa revision found in Launchpad for the given
source package, upstream version, and Ubuntu series set. The lookup is
paginated, retried, and fails closed if any source-history status cannot be
queried reliably.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      PACKAGE="${2:-}"
      shift 2
      ;;
    --upstream-version)
      UPSTREAM_VERSION="${2:-}"
      shift 2
      ;;
    --series)
      SERIES="${2:-}"
      shift 2
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

[[ -n "$PACKAGE" ]] || usage
[[ -n "$UPSTREAM_VERSION" ]] || usage
[[ -n "$SERIES" ]] || usage

export PPA_REV_PACKAGE="$PACKAGE"
export PPA_REV_UPSTREAM_VERSION="$UPSTREAM_VERSION"
export PPA_REV_SERIES="$SERIES"
export PPA_REV_OWNER="$OWNER"
export PPA_REV_ARCHIVE="$ARCHIVE"

python3 -u - <<'PY'
import json
import os
import re
import time
import urllib.parse
import urllib.request

package = os.environ["PPA_REV_PACKAGE"]
upstream = os.environ["PPA_REV_UPSTREAM_VERSION"]
series_list = os.environ["PPA_REV_SERIES"].split()
owner = os.environ["PPA_REV_OWNER"]
archive = os.environ["PPA_REV_ARCHIVE"]
base = f"https://api.launchpad.net/devel/~{owner}/+archive/ubuntu/{archive}"
statuses = ("Pending", "Published", "Superseded", "Deleted", "Obsolete")
rx = re.compile(
    rf"^{re.escape(upstream)}\+[A-Za-z0-9]+(?:\+[A-Za-z0-9.]+)*-0ppa([0-9]+)~"
)


def get_json(url):
    delay = 2
    last_exc = None
    for attempt in range(1, 6):
        try:
            request = urllib.request.Request(
                url,
                headers={"Accept": "application/json", "User-Agent": "bambustudio-ppa-revision"},
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except Exception as exc:
            last_exc = exc
            if attempt == 5:
                break
            print(
                f"Launchpad revision query attempt {attempt} failed: {exc}; retrying in {delay}s",
                file=os.sys.stderr,
                flush=True,
            )
            time.sleep(delay)
            delay = min(delay * 2, 20)
    raise RuntimeError(f"Launchpad revision query failed after retries: {last_exc}")


def collection_entries(first_url):
    entries = []
    url = first_url
    seen = set()
    while url:
        if url in seen:
            raise RuntimeError(f"Launchpad collection pagination loop detected at {url}")
        seen.add(url)
        data = get_json(url)
        if not isinstance(data, dict):
            raise RuntimeError(f"Expected Launchpad collection object from {url}")
        entries.extend(data.get("entries", []))
        next_url = data.get("next_collection_link")
        url = urllib.parse.urljoin(url, next_url) if next_url else None
    return entries


maximum = 0
for series in series_list:
    for status in statuses:
        query = urllib.parse.urlencode({
            "ws.op": "getPublishedSources",
            "source_name": package,
            "exact_match": "true",
            "distro_series": f"https://api.launchpad.net/devel/ubuntu/{series}",
            "status": status,
            "order_by_date": "true",
            "ws.size": 100,
        })
        entries = collection_entries(f"{base}?{query}")
        for entry in entries:
            version = str(entry.get("source_package_version", ""))
            match = rx.match(version)
            if match:
                maximum = max(maximum, int(match.group(1)))

print(maximum)
PY
