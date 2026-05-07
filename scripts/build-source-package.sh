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
REUSE_EXISTING_ORIG="${REUSE_EXISTING_ORIG:-1}"
PPA_ORIG_BASE_URL="${PPA_ORIG_BASE_URL:-}"
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
  --reuse-existing-orig 0|1   Reuse existing orig from PPA when excluding orig (default: 1)
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
    --reuse-existing-orig)
      REUSE_EXISTING_ORIG="$2"
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

SOURCE_PACKAGE_NAME="bambustudio"
BINARY_PACKAGE_NAME="bambustudio"
INSTALL_DIR="/opt/bambustudio"
WRAPPER_CMD="bambustudio"
DESKTOP_FILE="bambustudio.desktop"
DESKTOP_NAME="BambuStudio"
DESKTOP_COMMENT="A cutting-edge, feature-rich slicing software."
ICON_BASENAME="BambuStudio"
if [[ "$CHANNEL" == "beta" ]]; then
  SOURCE_PACKAGE_NAME="bambustudio-beta"
  BINARY_PACKAGE_NAME="bambustudio-beta"
  INSTALL_DIR="/opt/bambustudio-beta"
  WRAPPER_CMD="bambustudio-beta"
  DESKTOP_FILE="bambustudio-beta.desktop"
  DESKTOP_NAME="BambuStudio Beta"
  DESKTOP_COMMENT="Bambu Studio beta channel repackaged from the official Linux AppImage."
  ICON_BASENAME="BambuStudioBeta"
fi

prepare_source_tree() {
  local series="$1"
  local asset_url asset_name workspace source_dir package_version ubuntu_series_version series_upstream_version
  local launcher_path desktop_path icon_root orig_tarball orig_url debuild_source_args selected_include_mode
  local source_base_url

  ubuntu_series_version="$(series_version_suffix "$series")"
  series_upstream_version="${VERSION}+${series}"
  package_version="${series_upstream_version}-0ppa${PPA_REVISION}~${ubuntu_series_version}.1"
  workspace="$BUILD_ROOT/$series"
  source_dir="$workspace/${SOURCE_PACKAGE_NAME}-${series_upstream_version}"
  mkdir -p "$workspace"

  selected_include_mode="$SOURCE_INCLUDE_MODE"
  if [[ "$selected_include_mode" == "auto" ]]; then
    if (( PPA_REVISION > 1 )); then
      selected_include_mode="exclude-orig"
    else
      selected_include_mode="include-orig"
    fi
  fi

  debuild_source_args=(-S)
  case "$selected_include_mode" in
    include-orig)
      debuild_source_args+=(-sa)
      echo "Source include mode: include orig tarball (-sa)"
      ;;
    exclude-orig)
      debuild_source_args+=(-sd)
      echo "Source include mode: exclude orig tarball from .changes (-sd)"
      ;;
    *)
      die "Unknown selected source include mode: $selected_include_mode"
      ;;
  esac

  source_base_url="$PPA_ORIG_BASE_URL"
  if [[ -z "$source_base_url" ]]; then
    source_base_url="https://ppa.launchpadcontent.net/daddyparodz/bambustudio/ubuntu/pool/main/${SOURCE_PACKAGE_NAME:0:1}/${SOURCE_PACKAGE_NAME}"
  fi

  orig_tarball="$workspace/${SOURCE_PACKAGE_NAME}_${series_upstream_version}.orig.tar.xz"
  rm -f "$orig_tarball"
  if [[ "$selected_include_mode" == "exclude-orig" && "$REUSE_EXISTING_ORIG" == "1" ]]; then
    orig_url="${source_base_url}/${SOURCE_PACKAGE_NAME}_${series_upstream_version}.orig.tar.xz"
    if curl -fsSL "$orig_url" -o "$orig_tarball"; then
      echo "Reusing existing orig tarball from PPA: $orig_url"
      tar -C "$workspace" -xJf "$orig_tarball"
      if [[ ! -d "$source_dir" ]]; then
        die "Downloaded orig tarball did not contain expected source dir: $source_dir"
      fi
    fi
  fi

  if [[ ! -d "$source_dir" ]]; then
    mkdir -p "$source_dir"
    asset_url="$(appimage_asset_url "$RELEASE_JSON" "$series")"
    asset_name="$(basename "$asset_url")"

    curl -fL "$asset_url" -o "$source_dir/BambuStudio.AppImage"
    chmod 0755 "$source_dir/BambuStudio.AppImage"
    local appimage_size appimage_sha256
    appimage_size="$(stat -c '%s' "$source_dir/BambuStudio.AppImage")"
    appimage_sha256="$(sha256sum "$source_dir/BambuStudio.AppImage" | awk '{print $1}')"
    echo "Channel: ${CHANNEL}"
    echo "Source package: ${SOURCE_PACKAGE_NAME}"
    echo "Binary package: ${BINARY_PACKAGE_NAME}"
    echo "Series: ${series}"
    echo "Install path: ${INSTALL_DIR}/BambuStudio.AppImage"
    echo "Wrapper path: /usr/bin/${WRAPPER_CMD}"
    echo "Desktop file path: /usr/share/applications/${DESKTOP_FILE}"
    echo "Upstream tag: ${TAG}"
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
    sed -i \
      -e "s/@SOURCE_PACKAGE_NAME@/${SOURCE_PACKAGE_NAME}/g" \
      -e "s/@BINARY_PACKAGE_NAME@/${BINARY_PACKAGE_NAME}/g" \
      "$source_dir/debian/control"
    if [[ -f "$source_dir/debian/source/lintian-overrides" ]]; then
      sed -i "s/^bambustudio source:/${SOURCE_PACKAGE_NAME} source:/g" "$source_dir/debian/source/lintian-overrides"
    fi

    rm -f "$source_dir/debian/bambustudio.install"
    cat > "$source_dir/debian/${BINARY_PACKAGE_NAME}.install" <<EOF
BambuStudio.AppImage ${INSTALL_DIR}/
${WRAPPER_CMD} usr/bin/
${DESKTOP_FILE} usr/share/applications/
${ICON_BASENAME}.png usr/share/pixmaps/
icons/32x32/apps/${ICON_BASENAME}.png usr/share/icons/hicolor/32x32/apps/
icons/128x128/apps/${ICON_BASENAME}.png usr/share/icons/hicolor/128x128/apps/
icons/192x192/apps/${ICON_BASENAME}.png usr/share/icons/hicolor/192x192/apps/
EOF

    cat > "$source_dir/debian/tests/smoke" <<EOF
#!/bin/sh
set -eu

test -x ${INSTALL_DIR}/BambuStudio.AppImage
test -x /usr/bin/${WRAPPER_CMD}
test -f /usr/share/applications/${DESKTOP_FILE}
EOF
    chmod 0755 "$source_dir/debian/tests/smoke"

    if [[ -f "$source_dir/squashfs-root/BambuStudio.png" ]]; then
      cp "$source_dir/squashfs-root/BambuStudio.png" "$source_dir/${ICON_BASENAME}.png"
    else
      die "Missing top-level BambuStudio icon in upstream AppImage"
    fi

    icon_root="$source_dir/icons"
    mkdir -p "$icon_root"
    local size src dest
    for size in 32x32 128x128 192x192; do
      src="$source_dir/squashfs-root/usr/share/icons/hicolor/$size/apps/BambuStudio.png"
      dest="$icon_root/$size/apps/${ICON_BASENAME}.png"
      mkdir -p "$(dirname "$dest")"
      if [[ -f "$src" ]]; then
        cp "$src" "$dest"
      else
        cp "$source_dir/${ICON_BASENAME}.png" "$dest"
      fi
    done

    launcher_path="$source_dir/${WRAPPER_CMD}"
    cat > "$launcher_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APPIMAGE=@INSTALL_DIR@/BambuStudio.AppImage
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

if command -v xdg-mime >/dev/null 2>&1; then
  if [[ "$(xdg-mime query default x-scheme-handler/bambustudioopen 2>/dev/null || true)" != "@DESKTOP_FILE@" ]]; then
    xdg-mime default @DESKTOP_FILE@ x-scheme-handler/bambustudioopen x-scheme-handler/bambustudio >/dev/null 2>&1 || true
  fi
fi

exec "$APPIMAGE" "$@"
EOF
    sed -i \
      -e "s|@INSTALL_DIR@|${INSTALL_DIR}|g" \
      -e "s|@DESKTOP_FILE@|${DESKTOP_FILE}|g" \
      "$launcher_path"
    chmod 0755 "$launcher_path"

    desktop_path="$source_dir/${DESKTOP_FILE}"
    cat > "$desktop_path" <<EOF
[Desktop Entry]
Name=${DESKTOP_NAME}
GenericName=3D Printing Software
Comment=${DESKTOP_COMMENT}
Exec=/usr/bin/${WRAPPER_CMD} %U
Icon=${ICON_BASENAME}
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
${SOURCE_PACKAGE_NAME} (${package_version}) ${series}; urgency=medium

  * Repackage upstream release ${TAG}.
  * Bundle the official ${asset_name} AppImage for Ubuntu ${series}.

 -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  ${CHANGELOG_DATE}
EOF

    rm -rf "$source_dir/squashfs-root"
    rm -f "$orig_tarball"
    tar --exclude='./debian' -C "$workspace" -cJf "$orig_tarball" "${SOURCE_PACKAGE_NAME}-${series_upstream_version}"
  else
    rm -rf "$source_dir/debian"
    cp -a "$REPO_ROOT/packaging/debian" "$source_dir/debian"
    sed -i \
      -e "s/@SOURCE_PACKAGE_NAME@/${SOURCE_PACKAGE_NAME}/g" \
      -e "s/@BINARY_PACKAGE_NAME@/${BINARY_PACKAGE_NAME}/g" \
      "$source_dir/debian/control"
    if [[ -f "$source_dir/debian/source/lintian-overrides" ]]; then
      sed -i "s/^bambustudio source:/${SOURCE_PACKAGE_NAME} source:/g" "$source_dir/debian/source/lintian-overrides"
    fi
    rm -f "$source_dir/debian/bambustudio.install"
    cat > "$source_dir/debian/${BINARY_PACKAGE_NAME}.install" <<EOF
BambuStudio.AppImage ${INSTALL_DIR}/
${WRAPPER_CMD} usr/bin/
${DESKTOP_FILE} usr/share/applications/
${ICON_BASENAME}.png usr/share/pixmaps/
icons/32x32/apps/${ICON_BASENAME}.png usr/share/icons/hicolor/32x32/apps/
icons/128x128/apps/${ICON_BASENAME}.png usr/share/icons/hicolor/128x128/apps/
icons/192x192/apps/${ICON_BASENAME}.png usr/share/icons/hicolor/192x192/apps/
EOF
    cat > "$source_dir/debian/tests/smoke" <<EOF
#!/bin/sh
set -eu

test -x ${INSTALL_DIR}/BambuStudio.AppImage
test -x /usr/bin/${WRAPPER_CMD}
test -f /usr/share/applications/${DESKTOP_FILE}
EOF
    chmod 0755 "$source_dir/debian/tests/smoke"
    cat > "$source_dir/debian/changelog" <<EOF
${SOURCE_PACKAGE_NAME} (${package_version}) ${series}; urgency=medium

  * Rebuild Debian packaging revision for ${TAG}.

 -- ${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>  ${CHANGELOG_DATE}
EOF
  fi

  if [[ "$CHANNEL" == "beta" ]]; then
    if [[ -f "$source_dir/BambuStudio.png" && ! -f "$source_dir/BambuStudioBeta.png" ]]; then
      cp "$source_dir/BambuStudio.png" "$source_dir/BambuStudioBeta.png"
    fi
    local size old_icon new_icon
    for size in 32x32 128x128 192x192; do
      old_icon="$source_dir/icons/$size/apps/BambuStudio.png"
      new_icon="$source_dir/icons/$size/apps/BambuStudioBeta.png"
      mkdir -p "$(dirname "$new_icon")"
      if [[ -f "$old_icon" && ! -f "$new_icon" ]]; then
        cp "$old_icon" "$new_icon"
      elif [[ -f "$source_dir/BambuStudioBeta.png" && ! -f "$new_icon" ]]; then
        cp "$source_dir/BambuStudioBeta.png" "$new_icon"
      fi
    done
    cat > "$source_dir/debian/source/include-binaries" <<'EOF'
BambuStudioBeta.png
icons/32x32/apps/BambuStudioBeta.png
icons/128x128/apps/BambuStudioBeta.png
icons/192x192/apps/BambuStudioBeta.png
EOF
  fi

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
