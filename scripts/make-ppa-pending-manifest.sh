#!/usr/bin/env bash
set -euo pipefail

DIST_DIR=""
PACKAGE=""
CHANNEL=""
TAG=""
COMMIT=""
REVISION=""
CREATED_AT="${PPA_PENDING_CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

usage() {
  cat >&2 <<'USAGE'
Usage: make-ppa-pending-manifest.sh \
  --dist-dir DIR --package NAME --channel CHANNEL --tag TAG \
  --commit SHA --revision N

Prints a JSON manifest describing the exact Launchpad source versions that
were prepared for upload.
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist-dir) DIST_DIR="${2:-}"; shift 2 ;;
    --package) PACKAGE="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -d "$DIST_DIR" ]] || { echo "Missing dist dir: $DIST_DIR" >&2; exit 2; }
[[ -n "$PACKAGE" ]] || usage
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || { echo "Invalid channel: $CHANNEL" >&2; exit 2; }
[[ -n "$TAG" ]] || usage
[[ "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "Invalid commit: $COMMIT" >&2; exit 2; }
[[ "$REVISION" =~ ^[0-9]+$ ]] || { echo "Invalid revision: $REVISION" >&2; exit 2; }

export PPA_MANIFEST_DIST_DIR="$DIST_DIR"
export PPA_MANIFEST_PACKAGE="$PACKAGE"
export PPA_MANIFEST_CHANNEL="$CHANNEL"
export PPA_MANIFEST_TAG="$TAG"
export PPA_MANIFEST_COMMIT="$COMMIT"
export PPA_MANIFEST_REVISION="$REVISION"
export PPA_MANIFEST_CREATED_AT="$CREATED_AT"

python3 - <<'PY'
import glob
import json
import os
import pathlib


def field(path, name):
    prefix = f"{name}:"
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith(prefix):
                return line[len(prefix):].strip()
    return ""


dist_dir = pathlib.Path(os.environ["PPA_MANIFEST_DIST_DIR"])
package = os.environ["PPA_MANIFEST_PACKAGE"]
sources = []
seen = set()

for filename in sorted(glob.glob(str(dist_dir / "*_source.changes"))):
    path = pathlib.Path(filename)
    source = field(path, "Source")
    if source != package:
        continue
    version = field(path, "Version")
    series = field(path, "Distribution")
    if not version or not series:
        raise SystemExit(f"Could not parse Version/Distribution from {path}")
    key = (series, version)
    if key in seen:
        continue
    seen.add(key)
    sources.append({"series": series, "version": version})

if not sources:
    raise SystemExit(f"No source changes files found for {package} in {dist_dir}")

manifest = {
    "schema": 1,
    "status": "pending",
    "channel": os.environ["PPA_MANIFEST_CHANNEL"],
    "package": package,
    "tag": os.environ["PPA_MANIFEST_TAG"],
    "commit": os.environ["PPA_MANIFEST_COMMIT"],
    "revision": int(os.environ["PPA_MANIFEST_REVISION"]),
    "created_at": os.environ["PPA_MANIFEST_CREATED_AT"],
    "sources": sources,
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY
