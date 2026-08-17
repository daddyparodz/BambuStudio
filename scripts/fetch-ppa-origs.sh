#!/usr/bin/env bash
set -euo pipefail

PACKAGE=""
UPSTREAM_VERSION=""
SERIES=""
OUTPUT_DIR=""
OWNER="${PPA_OWNER:-daddyparodz}"
ARCHIVE="${PPA_ARCHIVE:-bambustudio}"

usage() {
  cat >&2 <<'EOF'
Usage: fetch-ppa-origs.sh --package NAME --upstream-version VERSION --series "jammy noble" --output-dir DIR

Fetches the exact existing orig tarball for each Ubuntu series. It first uses the
public PPA pool. If a file was removed from the pool by an earlier retention
mistake, it asks Launchpad for recently deleted/superseded source publications
and downloads the retained Librarian copy.

Exit status 3 means there is no historical publication for the requested
upstream version/series, so callers may safely create and upload a new orig.
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
    --output-dir)
      OUTPUT_DIR="${2:-}"
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
[[ -n "$OUTPUT_DIR" ]] || usage

mkdir -p "$OUTPUT_DIR"

export FETCH_PPA_PACKAGE="$PACKAGE"
export FETCH_PPA_UPSTREAM_VERSION="$UPSTREAM_VERSION"
export FETCH_PPA_SERIES="$SERIES"
export FETCH_PPA_OUTPUT_DIR="$OUTPUT_DIR"
export FETCH_PPA_OWNER="$OWNER"
export FETCH_PPA_ARCHIVE="$ARCHIVE"

python3 -u - <<'PY'
import json
import os
import pathlib
import time
import urllib.parse
import urllib.request

package = os.environ["FETCH_PPA_PACKAGE"]
upstream = os.environ["FETCH_PPA_UPSTREAM_VERSION"]
series_list = os.environ["FETCH_PPA_SERIES"].split()
outdir = pathlib.Path(os.environ["FETCH_PPA_OUTPUT_DIR"])
owner = os.environ["FETCH_PPA_OWNER"]
archive = os.environ["FETCH_PPA_ARCHIVE"]
api_base = f"https://api.launchpad.net/devel/~{owner}/+archive/ubuntu/{archive}"
pool_base = (
    f"https://ppa.launchpadcontent.net/{owner}/{archive}/ubuntu/pool/main/"
    f"{package[0]}/{package}"
)


def open_url(url, timeout=30):
    delay = 2
    last_exc = None
    for attempt in range(1, 6):
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "bambustudio-ppa-orig-recovery"},
            )
            return urllib.request.urlopen(req, timeout=timeout)
        except Exception as exc:
            last_exc = exc
            if attempt == 5:
                break
            print(f"Fetch attempt {attempt} failed for {url}: {exc}; retrying in {delay}s", flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 20)
    raise last_exc


def get_json(url):
    with open_url(url) as response:
        return json.load(response)


def download(url, destination):
    tmp = destination.with_suffix(destination.suffix + ".tmp")
    with open_url(url, timeout=120) as response, tmp.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)
    if tmp.stat().st_size < 1024:
        raise RuntimeError(f"Downloaded orig is unexpectedly small: {tmp}")
    tmp.replace(destination)


def source_entries(series, status):
    query = urllib.parse.urlencode({
        "ws.op": "getPublishedSources",
        "source_name": package,
        "exact_match": "true",
        "distro_series": f"https://api.launchpad.net/devel/ubuntu/{series}",
        "status": status,
        "order_by_date": "true",
        "ws.size": 100,
    })
    return get_json(f"{api_base}?{query}").get("entries", [])


def source_file_urls(publication_link):
    separator = "&" if "?" in publication_link else "?"
    data = get_json(f"{publication_link}{separator}ws.op=sourceFileUrls&include_meta=true")
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        if "entries" in data:
            return data["entries"]
        if "urls" in data:
            return data["urls"]
    return []


for series in series_list:
    series_upstream = f"{upstream}+{series}"
    filename = f"{package}_{series_upstream}.orig.tar.xz"
    destination = outdir / filename
    pool_url = f"{pool_base}/{filename}"

    try:
        download(pool_url, destination)
        print(f"ORIG OK: {package}/{series} from PPA pool: {pool_url}", flush=True)
        continue
    except Exception as exc:
        print(f"PPA pool orig unavailable for {package}/{series}: {exc}", flush=True)

    wanted_prefix = f"{series_upstream}-0ppa"
    recovered = False
    historical_match_seen = False
    for status in ("Pending", "Published", "Superseded", "Deleted"):
        try:
            entries = source_entries(series, status)
        except Exception as exc:
            print(f"Launchpad query failed for {package}/{series} status={status}: {exc}", flush=True)
            continue

        matches = [
            entry for entry in entries
            if str(entry.get("source_package_version", "")).startswith(wanted_prefix)
        ]
        if matches:
            historical_match_seen = True
        matches.sort(
            key=lambda entry: (
                str(entry.get("date_created", "")),
                str(entry.get("date_published", "")),
                str(entry.get("self_link", "")),
            ),
            reverse=True,
        )

        for entry in matches:
            publication_link = entry.get("self_link")
            if not publication_link:
                continue
            try:
                files = source_file_urls(publication_link)
            except Exception as exc:
                print(f"Could not list source files for {publication_link}: {exc}", flush=True)
                continue

            for item in files:
                if isinstance(item, str):
                    url = item
                    item_name = pathlib.PurePosixPath(urllib.parse.urlparse(url).path).name
                elif isinstance(item, dict):
                    url = item.get("url") or item.get("file_url")
                    item_name = item.get("filename") or (
                        pathlib.PurePosixPath(urllib.parse.urlparse(url).path).name if url else ""
                    )
                else:
                    continue

                if not url or item_name != filename:
                    continue
                try:
                    download(url, destination)
                except Exception as exc:
                    print(f"Could not recover {filename} from {url}: {exc}", flush=True)
                    continue
                print(
                    f"ORIG RECOVERED: {package}/{series} from {status} publication {publication_link}",
                    flush=True,
                )
                recovered = True
                break
            if recovered:
                break
        if recovered:
            break

    if recovered:
        continue
    if not historical_match_seen:
        print(
            f"ORIG NEW: no historical {package}/{series} publication exists for {series_upstream}; "
            "caller may create a new orig tarball.",
            flush=True,
        )
        raise SystemExit(3)

    raise SystemExit(
        f"Unable to recover exact existing orig tarball for {package}/{series}: {filename}. "
        "Refusing to regenerate an orig with the same upstream filename because Launchpad "
        "rejects same-name orig files whose contents differ."
    )

print(f"Recovered all required orig tarballs into {outdir}", flush=True)
PY
