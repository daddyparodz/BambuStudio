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

Exit status 3 means the requested revision is safe to supersede because either
Launchpad was queried successfully and no active source exists in any expected
series, or release-state already records that exact tag/revision as a terminal
failure. Other nonzero statuses mean recovery could not be determined safely
and callers must fail closed.

Because an older Launchpad artifact does not carry reliable Git commit
provenance, recovery never attributes it to a newer current commit. It records
the previously verified release-state commit as a conservative packaged
baseline, so any repository changes after that commit are still rebuilt by the
next sync.
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
[[ "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "Invalid current commit: $COMMIT" >&2; exit 2; }
[[ "$REVISION" =~ ^[0-9]+$ ]] || { echo "Invalid revision: $REVISION" >&2; exit 2; }
[[ -n "$SERIES" ]] || usage

repo_root="$(git rev-parse --show-toplevel)"
release_state_ref="refs/remotes/origin/release-state"
verified_commit_path="state/latest-${CHANNEL}-commit.txt"
failed_release_path="state/failed-${CHANNEL}.json"

if ! git -C "$repo_root" cat-file -e "${release_state_ref}:${verified_commit_path}" 2>/dev/null; then
  echo "Cannot recover ${CHANNEL}: missing verified release-state commit marker." >&2
  exit 1
fi
verified_commit="$(git -C "$repo_root" show "${release_state_ref}:${verified_commit_path}" | tr -d '\n')"
if [[ ! "$verified_commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Cannot recover ${CHANNEL}: invalid verified release-state commit: $verified_commit" >&2
  exit 1
fi
if ! git -C "$repo_root" cat-file -e "${verified_commit}^{commit}" 2>/dev/null; then
  echo "Cannot recover ${CHANNEL}: verified commit is not present in repository history: $verified_commit" >&2
  exit 1
fi
if ! git -C "$repo_root" merge-base --is-ancestor "$verified_commit" "$COMMIT"; then
  echo "Cannot recover ${CHANNEL}: verified commit $verified_commit is not an ancestor of current commit $COMMIT" >&2
  exit 1
fi

# A revision that release-state already records as terminally failed must not
# be recovered again after release-input changes authorize a superseding
# upload. The workflow's failed-state gate runs before this helper, so reaching
# this path for the same failed tag/revision means a newer revision is allowed.
if git -C "$repo_root" cat-file -e "${release_state_ref}:${failed_release_path}" 2>/dev/null; then
  failed_state="$(git -C "$repo_root" show "${release_state_ref}:${failed_release_path}")"
  failed_tag="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag", ""))' <<<"$failed_state")"
  failed_revision="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("revision", ""))' <<<"$failed_state")"
  if [[ "$failed_tag" == "$TAG" && "$failed_revision" == "$REVISION" ]]; then
    echo "Recovery skipped for ${CHANNEL} ${TAG} ppa${REVISION}: release-state already records this revision as terminally failed." >&2
    exit 3
  fi
fi

if [[ "$verified_commit" == "$COMMIT" ]]; then
  commit_provenance="verified-current"
else
  commit_provenance="verified-baseline"
  echo "Recovery will keep verified baseline commit $verified_commit instead of attributing the older artifact to current commit $COMMIT." >&2
fi

export PPA_DISCOVER_PACKAGE="$PACKAGE"
export PPA_DISCOVER_CHANNEL="$CHANNEL"
export PPA_DISCOVER_TAG="$TAG"
export PPA_DISCOVER_COMMIT="$verified_commit"
export PPA_DISCOVER_REQUESTED_COMMIT="$COMMIT"
export PPA_DISCOVER_COMMIT_PROVENANCE="$commit_provenance"
export PPA_DISCOVER_REVISION="$REVISION"
export PPA_DISCOVER_SERIES="$SERIES"
export PPA_DISCOVER_OWNER="$OWNER"
export PPA_DISCOVER_ARCHIVE="$ARCHIVE"
export PPA_DISCOVER_CREATED_AT="$CREATED_AT"

python3 - <<'PY'
import json
import os
import re
import sys

from launchpadlib.launchpad import Launchpad

package = os.environ["PPA_DISCOVER_PACKAGE"]
channel = os.environ["PPA_DISCOVER_CHANNEL"]
tag = os.environ["PPA_DISCOVER_TAG"]
commit = os.environ["PPA_DISCOVER_COMMIT"]
requested_commit = os.environ["PPA_DISCOVER_REQUESTED_COMMIT"]
commit_provenance = os.environ["PPA_DISCOVER_COMMIT_PROVENANCE"]
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

matches_by_series = {}
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
    matches_by_series[series] = matches

active_match_count = sum(len(matches) for matches in matches_by_series.values())
if active_match_count == 0:
    print(
        f"No active Launchpad sources found for {package} revision ppa{revision} "
        f"across expected series {series_list}",
        file=sys.stderr,
    )
    raise SystemExit(3)

sources = []
for series in series_list:
    matches = matches_by_series[series]
    if len(matches) != 1:
        raise SystemExit(
            f"Cannot safely recover {package} revision ppa{revision}: expected exactly one "
            f"active source for {series}, found {matches}. Partial or ambiguous active "
            f"history must not be superseded automatically."
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
    "commit_provenance": commit_provenance,
    "recovery_requested_commit": requested_commit,
    "sources": sources,
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY
