#!/usr/bin/env bash
set -euo pipefail

if ! command -v ubuntu-distro-info >/dev/null 2>&1; then
  echo "ubuntu-distro-info is required" >&2
  exit 1
fi

# Launchpad PPAs only accept active Ubuntu series. `--supported` includes
# currently supported stable releases and the current development series.
ubuntu-distro-info --supported | tr '\n' ' ' | sed -E 's/[[:space:]]+$//'
