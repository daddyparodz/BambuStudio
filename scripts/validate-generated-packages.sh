#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${1:-$REPO_ROOT/dist}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/validate}"
PPA_REVISION="${PPA_REVISION:-1}"
SOURCE_INCLUDE_MODE="${SOURCE_INCLUDE_MODE:-auto}"

mkdir -p "$WORK_DIR"
rm -rf "$WORK_DIR"/*

shopt -s nullglob
changes_files=("$DIST_DIR"/*_source.changes)
if (( ${#changes_files[@]} == 0 )); then
  echo "No source changes files found in $DIST_DIR" >&2
  exit 1
fi

for changes in "${changes_files[@]}"; do
  pkg_base="$(basename "$changes" _source.changes)"
  dsc="$DIST_DIR/${pkg_base}.dsc"
  if [[ ! -f "$dsc" ]]; then
    echo "Missing dsc for $changes" >&2
    exit 1
  fi

  stage="$WORK_DIR/$pkg_base"
  mkdir -p "$stage"
  find "$DIST_DIR" -maxdepth 1 -type f -exec cp -f {} "$stage/" \;

  (
    cd "$stage"
    dpkg-source -x "$(basename "$dsc")"
    srcdir="$(find . -maxdepth 1 -type d \( -name 'bambustudio-*' -o -name 'bambustudio-beta-*' \) | head -n1)"
    appimg="$srcdir/BambuStudio.AppImage"
    appimg_size="$(stat -c '%s' "$appimg")"
    echo "Validating source AppImage for $pkg_base (size=$appimg_size)"
    if (( appimg_size < 100000000 )); then
      echo "Source AppImage too small in $pkg_base" >&2
      exit 1
    fi
    chmod +x "$appimg"
    "$appimg" --appimage-extract >/dev/null
    test -f squashfs-root/AppRun || test -f "$srcdir/squashfs-root/AppRun"
    rm -rf squashfs-root "$srcdir/squashfs-root"

    (
      cd "$srcdir"
      dpkg-buildpackage -b -us -uc
    )

    deb="$(find . -maxdepth 1 -type f \( -name 'bambustudio_*_amd64.deb' -o -name 'bambustudio-beta_*_amd64.deb' \) | head -n1)"
    mkdir -p debroot
    dpkg-deb -x "$deb" debroot
    staged_appimg="$(find debroot/opt -maxdepth 3 -type f -name 'BambuStudio.AppImage' | head -n1)"
    if [[ -z "$staged_appimg" ]]; then
      echo "No staged AppImage found in built deb for $pkg_base" >&2
      exit 1
    fi
    if [[ "$staged_appimg" == *"/opt/bambustudio-beta/"* ]]; then
      staged_wrapper="debroot/usr/bin/bambustudio-beta"
      staged_desktop="debroot/usr/share/applications/bambustudio-beta.desktop"
    else
      staged_wrapper="debroot/usr/bin/bambustudio"
      staged_desktop="debroot/usr/share/applications/bambustudio.desktop"
    fi
    staged_size="$(stat -c '%s' "$staged_appimg")"
    echo "Validating built deb AppImage for $pkg_base (size=$staged_size)"
    if (( staged_size < 100000000 )); then
      echo "Built deb AppImage too small in $pkg_base" >&2
      exit 1
    fi
    chmod +x "$staged_appimg"
    "$staged_appimg" --appimage-extract >/dev/null
    test -f squashfs-root/AppRun
    test -x "$staged_wrapper"
    test -f "$staged_desktop"
  )

  expect_exclude_orig=false
  case "$SOURCE_INCLUDE_MODE" in
    exclude-orig)
      expect_exclude_orig=true
      ;;
    include-orig)
      expect_exclude_orig=false
      ;;
    auto)
      # Auto mode is intentionally non-strict here because remote archive
      # visibility can race/flap during CI. Build/upload scripts decide whether
      # to include orig; validation should not second-guess it.
      expect_exclude_orig=false
      ;;
    *)
      echo "Unsupported SOURCE_INCLUDE_MODE: $SOURCE_INCLUDE_MODE" >&2
      exit 1
      ;;
  esac

  if [[ "$expect_exclude_orig" == "true" ]]; then
    echo "Checking .changes excludes .orig.tar for $pkg_base"
    if grep -qE '\.orig\.tar\.(gz|bz2|xz|lzma)$' "$changes"; then
      echo "Found forbidden orig tarball entry in $changes for PPA_REVISION=${PPA_REVISION}" >&2
      exit 1
    fi
  fi
done

echo "All generated source packages and deb payloads validated."
