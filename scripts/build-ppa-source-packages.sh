#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHANNEL="${CHANNEL:-stable}"
RELEASE_TAG="${RELEASE_TAG:-}"
PPA_REVISION="${PPA_REVISION:-1}"
SERIES="${SERIES_OVERRIDE:-}"
SIGN_SOURCE="${SIGN_SOURCE:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"

if [[ -z "$RELEASE_TAG" ]]; then
  echo "RELEASE_TAG is required" >&2
  exit 2
fi
if ! [[ "$PPA_REVISION" =~ ^[0-9]+$ ]]; then
  echo "PPA_REVISION must be numeric" >&2
  exit 2
fi
case "$CHANNEL" in
  stable|beta) ;;
  *) echo "CHANNEL must be stable or beta" >&2; exit 2 ;;
esac

if [[ -z "$SERIES" ]]; then
  SERIES="$("$SCRIPT_DIR/list-ubuntu-series.sh")"
fi

if [[ "$CHANNEL" == "beta" ]]; then
  SOURCE_PACKAGE_NAME="bambustudio-beta"
else
  SOURCE_PACKAGE_NAME="bambustudio"
fi
UPSTREAM_VERSION="${RELEASE_TAG#v}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

orig_cache="$(mktemp -d)"
cleanup() {
  rm -rf "$orig_cache"
}
trap cleanup EXIT

for series in $SERIES; do
  include_mode="include-orig"
  orig_base_url=""

  # If this upstream/series has ever existed in the PPA, reuse the exact orig.
  # Launchpad rejects a same-name orig tarball when its bytes differ, even if
  # the old publication was deleted. A brand-new series is the only safe case
  # for creating a fresh orig with the existing upstream naming scheme.
  set +e
  "$SCRIPT_DIR/fetch-ppa-origs.sh" \
    --package "$SOURCE_PACKAGE_NAME" \
    --upstream-version "$UPSTREAM_VERSION" \
    --series "$series" \
    --output-dir "$orig_cache"
  fetch_status=$?
  set -e

  case "$fetch_status" in
    0)
      include_mode="exclude-orig"
      orig_base_url="file://$orig_cache"
      ;;
    3)
      include_mode="include-orig"
      ;;
    *)
      echo "Could not prepare a safe orig tarball for ${SOURCE_PACKAGE_NAME}/${series}" >&2
      exit "$fetch_status"
      ;;
  esac

  build_root="$REPO_ROOT/build/ppa-${CHANNEL}-${series}"
  rm -rf "$build_root"

  args=(
    --channel "$CHANNEL"
    --release-tag "$RELEASE_TAG"
    --series "$series"
    --output-dir "$OUTPUT_DIR"
    --build-root "$build_root"
    --ppa-revision "$PPA_REVISION"
    --source-include-mode "$include_mode"
  )

  if [[ "$include_mode" == "exclude-orig" ]]; then
    export PPA_ORIG_BASE_URL="$orig_base_url"
    args+=(--reuse-existing-orig 1)
  else
    unset PPA_ORIG_BASE_URL || true
  fi

  if [[ "$SIGN_SOURCE" == "1" ]]; then
    args+=(--sign)
  fi

  echo "Building ${SOURCE_PACKAGE_NAME} for ${series}: revision=${PPA_REVISION}, source_mode=${include_mode}"
  "$SCRIPT_DIR/build-source-package.sh" "${args[@]}"
done

echo "Built PPA source packages for ${CHANNEL} ${RELEASE_TAG} into ${OUTPUT_DIR}"
