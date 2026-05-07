#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./lib/upstream.sh
source "$SCRIPT_DIR/lib/upstream.sh"

SERIES="${UBUNTU_SERIES:-$("$SCRIPT_DIR/list-ubuntu-series.sh")}"
CHANNEL="${CHANNEL:-stable}"
RELEASE_TAG="${RELEASE_TAG:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build}"
PPA_REVISION="${PPA_REVISION:-1}"
SIGN_SOURCE="${SIGN_SOURCE:-0}"
SOURCE_INCLUDE_MODE="${SOURCE_INCLUDE_MODE:-auto}"
MAINTAINER_NAME="${MAINTAINER_NAME:-daddyparodz}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-45983094+daddyparodz@users.noreply.github.com}"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --channel stable|beta       Release channel to package (default: stable)
  --release-tag TAG           Specific upstream tag, for example v02.06.00.51
  --series "jammy noble"      Space-separated Ubuntu series list
  --output-dir DIR            Directory for generated source package artifacts
  --build-root DIR            Directory for temporary package worktrees
  --ppa-revision N            PPA revision suffix, defaults to 1
  --source-include-mode MODE  auto|include-orig|exclude-orig (default: auto)
  --sign                      Sign source packages with debuild
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="$2"
      shift 2
      ;;
    --release-tag)
      RELEASE_TAG="$2"
      shift 2
      ;;
    --series)
      SERIES="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --build-root)
      BUILD_ROOT="$2"
      shift 2
      ;;
    --ppa-revision)
      PPA_REVISION="$2"
      shift 2
      ;;
    --source-include-mode)
      SOURCE_INCLUDE_MODE="$2"
      shift 2
      ;;
    --sign)
      SIGN_SOURCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$CHANNEL" in
  stable|beta) ;;
  *) die "CHANNEL must be stable or beta" ;;
esac

case "$SOURCE_INCLUDE_MODE" in
  auto|include-orig|exclude-orig) ;;
  *) die "SOURCE_INCLUDE_MODE must be auto, include-orig, or exclude-orig" ;;
esac

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT"
rm -rf "$BUILD_ROOT"/*

if [[ -n "$RELEASE_TAG" ]]; then
  RELEASE_JSON="$(release_json_for_tag "$RELEASE_TAG")"
else
  RELEASE_JSON="$(latest_release_json "$CHANNEL")"
fi

if [[ -z "$RELEASE_JSON" || "$RELEASE_JSON" == "null" ]]; then
  die "No matching upstream release found."
fi

TAG="$(jq -r '.tag_name' <<<"$RELEASE_JSON")"
VERSION="$(release_version_from_tag "$TAG")"
PUBLISHED_AT="$(jq -r '.published_at // empty' <<<"$RELEASE_JSON")"
if [[ -z "$PUBLISHED_AT" ]]; then
  CHANGELOG_DATE="$(date -Ru)"
else
  CHANGELOG_DATE="$(date -Ru -d "$PUBLISHED_AT")"
fi

prepare_source_tree() {
  local series="$1"
  local asset_url asset_name workspace source_dir package_version ubuntu_series_version series_upstream_version launcher_path desktop_path icon_root orig_tarball debuild_source_args

  ubuntu_series_version="$(series_version_suffix "$series")"
  series_upstream_version="${VERSION}+${series}"
  package_version="${series_upstream_version}-0ppa${PPA_REVISION}~${ubuntu_series_version}.1"
  workspace="$BUILD_ROOT/$series"
  source_dir="$workspace/bambustudio-${series_upstream_version}"
  mkdir -p "$workspace"
  mkdir -p "$source_dir"

  asset_url="$(appimage_asset_url "$RELEASE_JSON" "$series")"
  asset_name="$(basename "$asset_url")"

  curl -fL "$asset_url" -o "$source_dir/BambuStudio.AppImage"
  chmod 0755 "$source_dir/BambuStudio.AppImage"
  local appimage_size appimage_sha256
  appimage_size="$(stat -c '%s' "$source_dir/BambuStudio.AppImage")"
  appimage_sha256="$(sha256sum "$source_dir/BambuStudio.AppImage" | awk '{print $1}')"
  echo "Series: ${series}"
  echo "Asset URL: ${asset_url}"
  echo "Asset size (bytes): ${appimage_size}"
  echo "Asset sha256: ${appimage_sha256}"
  if (( appimage_size < 100000000 )); then
    die "Downloaded AppImage is unexpectedly small (${appimage_size} bytes)"
  fi

  (
    cd "$source_dir"
    ./BambuStudio.AppImage --appimage-extract >/dev/null
  )

  cp -a "$REPO_ROOT/packaging/debian" "$source_dir/debian"

  if [[ -f "$source_dir/squashfs-root/BambuStudio.png" ]]; then
    cp "$source_dir/squashfs-root/BambuStudio.png" "$source_dir/BambuStudio.png"
  else
    die "Missing top-level BambuStudio icon in upstream AppImage"
  fi

  icon_root="$source_dir/icons"
  mkdir -p "$icon_root"
  local size src dest
  for size in 32x32 128x128 192x192; do
    src="$source_dir/squashfs-root/usr/share/icons/hicolor/$size/apps/BambuStudio.png"
    dest="$icon_root/$size/apps/BambuStudio.png"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$src" ]]; then
      cp "$src" "$dest"
    else
      cp "$source_dir/BambuStudio.png" "$dest"
    fi
  done

  launcher_path="$source_dir/bambustudio"
  cat > "$launcher_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APPIMAGE=/opt/bambustudio/BambuStudio.AppImage
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

if command -v xdg-mime >/dev/null 2>&1; then
  if [[ "$(xdg-mime query default x-scheme-handler/bambustudioopen 2>/dev/null || true)" != "bambustudio.desktop" ]]; then
    xdg-mime default bambustudio.desktop x-scheme-handler/bambustudioopen x-scheme-handler/bambustudio >/dev/null 2>&1 || true
  fi
fi

exec "$APPIMAGE" "$@"
EOF
  chmod 0755 "$launcher_path"

  desktop_path="$source_dir/bambustudio.desktop"
  cat > "$desktop_path" <<EOF
[Desktop Entry]
Name=BambuStudio
GenericName=3D Printing Software
Comment=A cutting-edge, feature-rich slicing software.
Exec=/usr/bin/bambustudio %U
Icon=BambuStudio
Terminal=false
Type=Application
Categories=Graphics;3DGraphics;Engineering;
MimeType=model/stl;model/3mf;application/vnd.ms-3mfdocument;application/prs.wavefront-obj;application/x-amf;x-scheme-handler/bambustudio;x-scheme-handler/bambustudioopen;
Keywords=3D;Printing;Slicer;slice;3D;printer;convert;gcode;stl;obj;amf;SLA
StartupNotify=false
StartupWMClass=bambu-studio
X-AppImage-Version=${VERSION}
EOF

  cat > "$source_dir/debian/changelog" <<EOF
bambustudio (${package_version}) ${series}; urgency=medium

  * Repackage upstream release ${TAG}.
  * Bundle the official ${asset_name} AppImage for Ubuntu ${series}.

 -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  ${CHANGELOG_DATE}
EOF

  rm -rf "$source_dir/squashfs-root"

  orig_tarball="$workspace/bambustudio_${series_upstream_version}.orig.tar.xz"
  rm -f "$orig_tarball"
  tar --exclude='./debian' -C "$workspace" -cJf "$orig_tarball" "bambustudio-${series_upstream_version}"

  debuild_source_args=(-S)
  case "$SOURCE_INCLUDE_MODE" in
    include-orig)
      debuild_source_args+=(-sa)
      echo "Source include mode: include orig tarball (-sa)"
      ;;
    exclude-orig)
      debuild_source_args+=(-sd)
      echo "Source include mode: exclude orig tarball from .changes (-sd)"
      ;;
    auto)
      if (( PPA_REVISION > 1 )); then
        debuild_source_args+=(-sd)
        echo "Source include mode: exclude orig tarball from .changes (-sd)"
      else
        debuild_source_args+=(-sa)
        echo "Source include mode: include orig tarball (-sa)"
      fi
      ;;
  esac

  (
    cd "$source_dir"

    if [[ "$SIGN_SOURCE" == "1" ]]; then
      if [[ -n "${DEBSIGN_KEYID:-}" ]]; then
        debuild "${debuild_source_args[@]}" -k"${DEBSIGN_KEYID}"
      else
        debuild "${debuild_source_args[@]}"
      fi
    else
      debuild "${debuild_source_args[@]}" -us -uc
    fi
  )
}

for series in $SERIES; do
  prepare_source_tree "$series"
done

find "$BUILD_ROOT" -maxdepth 1 -type f \
  \( -name '*.dsc' -o -name '*.debian.tar.xz' -o -name '*.orig.tar.xz' -o -name '*_source.changes' -o -name '*.buildinfo' \) \
  -exec cp -f {} "$OUTPUT_DIR/" \;

find "$BUILD_ROOT" -mindepth 2 -maxdepth 2 -type f \
  \( -name '*.dsc' -o -name '*.debian.tar.xz' -o -name '*.orig.tar.xz' -o -name '*_source.changes' -o -name '*.buildinfo' \) \
  -exec cp -f {} "$OUTPUT_DIR/" \;

echo "Built source packages for ${TAG} into ${OUTPUT_DIR}"
