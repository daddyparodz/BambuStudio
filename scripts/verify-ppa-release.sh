#!/usr/bin/env bash
set -euo pipefail

PACKAGE=""
DIST_DIR=""
OWNER="${PPA_OWNER:-daddyparodz}"
ARCHIVE="${PPA_ARCHIVE:-bambustudio}"
SOURCE_TIMEOUT="${PPA_SOURCE_TIMEOUT:-1200}"
BUILD_TIMEOUT="${PPA_BUILD_TIMEOUT:-3600}"

usage() {
  cat >&2 <<'EOF'
Usage: verify-ppa-release.sh --package NAME --dist-dir DIR

Waits until Launchpad exposes every exact source version from the generated
_source.changes files, then waits for all corresponding Launchpad builds to
finish successfully.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      PACKAGE="${2:-}"
      shift 2
      ;;
    --dist-dir)
      DIST_DIR="${2:-}"
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
[[ -n "$DIST_DIR" ]] || usage
[[ -d "$DIST_DIR" ]] || { echo "Missing dist dir: $DIST_DIR" >&2; exit 2; }

export VERIFY_PPA_PACKAGE="$PACKAGE"
export VERIFY_PPA_DIST_DIR="$DIST_DIR"
export VERIFY_PPA_OWNER="$OWNER"
export VERIFY_PPA_ARCHIVE="$ARCHIVE"
export VERIFY_PPA_SOURCE_TIMEOUT="$SOURCE_TIMEOUT"
export VERIFY_PPA_BUILD_TIMEOUT="$BUILD_TIMEOUT"

python3 -u - <<'PY'
import glob
import os
import pathlib
import time

from launchpadlib.launchpad import Launchpad

package = os.environ["VERIFY_PPA_PACKAGE"]
dist_dir = pathlib.Path(os.environ["VERIFY_PPA_DIST_DIR"])
owner = os.environ["VERIFY_PPA_OWNER"]
archive_name = os.environ["VERIFY_PPA_ARCHIVE"]
source_timeout = int(os.environ["VERIFY_PPA_SOURCE_TIMEOUT"])
build_timeout = int(os.environ["VERIFY_PPA_BUILD_TIMEOUT"])


def field(path, name):
    prefix = f"{name}:"
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith(prefix):
                return line[len(prefix):].strip()
    return ""


expected = []
for filename in sorted(glob.glob(str(dist_dir / "*_source.changes"))):
    path = pathlib.Path(filename)
    source = field(path, "Source")
    version = field(path, "Version")
    series = field(path, "Distribution")
    if source != package:
        continue
    if not version or not series:
        raise SystemExit(f"Could not parse Version/Distribution from {path}")
    expected.append((series, version))

if not expected:
    raise SystemExit(f"No source changes files found for {package} in {dist_dir}")

print("Expected Launchpad sources:")
for series, version in expected:
    print(f"  {package} {series} {version}")

lp = Launchpad.login_anonymously(
    "bambustudio-ppa-release-verifier",
    "production",
    version="devel",
)
ppa = lp.people[owner].getPPAByName(name=archive_name)
ubuntu = lp.distributions["ubuntu"]

publications = {}
pending_sources = set(expected)
source_deadline = time.monotonic() + source_timeout

while pending_sources:
    for series, version in sorted(tuple(pending_sources)):
        distro_series = ubuntu.getSeries(name_or_version=series)
        found = None
        for status in ("Pending", "Published"):
            try:
                pubs = ppa.getPublishedSources(
                    source_name=package,
                    exact_match=True,
                    distro_series=distro_series,
                    status=status,
                    order_by_date=True,
                )
            except Exception as exc:
                print(f"Launchpad source query failed for {series}/{status}: {exc}", flush=True)
                continue
            for pub in pubs:
                if str(pub.source_package_version) == version:
                    found = pub
                    break
            if found is not None:
                break
        if found is not None:
            publications[(series, version)] = found
            pending_sources.discard((series, version))
            print(f"SOURCE ACCEPTED: {package} {series} {version} status={found.status}", flush=True)

    if not pending_sources:
        break
    if time.monotonic() >= source_deadline:
        print("Timed out waiting for Launchpad source acceptance:")
        for item in sorted(pending_sources):
            print(f"  {item}")
        raise SystemExit(1)
    print(f"Waiting for Launchpad source acceptance: {len(pending_sources)} remaining", flush=True)
    time.sleep(20)

pending_builds = set(expected)
last_states = {}
build_deadline = time.monotonic() + build_timeout
failure_states = {
    "Failed to build",
    "Chroot problem",
    "Failed to upload",
    "Cancelled build",
    "Build for superseded Source",
}

while pending_builds:
    for key in sorted(tuple(pending_builds)):
        pub = publications[key]
        try:
            builds = list(pub.getBuilds())
        except Exception as exc:
            print(f"Launchpad build query failed for {key}: {exc}", flush=True)
            continue
        if not builds:
            continue

        states = tuple(sorted(str(build.buildstate) for build in builds))
        if last_states.get(key) != states:
            print(f"BUILDS: {package} {key[0]} {key[1]} states={states}", flush=True)
            last_states[key] = states

        failed = [state for state in states if state in failure_states]
        if failed:
            raise SystemExit(
                f"Launchpad build failure for {package} {key[0]} {key[1]}: {failed}"
            )
        if states and all(state == "Successfully built" for state in states):
            pending_builds.discard(key)
            print(f"BUILD SUCCESS: {package} {key[0]} {key[1]}", flush=True)

    if not pending_builds:
        break
    if time.monotonic() >= build_deadline:
        print("Timed out waiting for Launchpad builds:")
        for item in sorted(pending_builds):
            print(f"  {item}: {last_states.get(item, ('not visible yet',))}")
        raise SystemExit(1)
    print(f"Waiting for Launchpad builds: {len(pending_builds)} source(s) remaining", flush=True)
    time.sleep(30)

print("All expected Launchpad source publications and builds succeeded.")
PY
