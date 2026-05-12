#!/usr/bin/env bash
set -euo pipefail

if ! command -v ubuntu-distro-info >/dev/null 2>&1; then
  echo "ubuntu-distro-info is required" >&2
  exit 1
fi

# Auto-include supported Ubuntu series, but exclude the active development
# codename to avoid pre-release publication failures.
supported="$(ubuntu-distro-info --supported | tr '\n' ' ')"
devel="$(ubuntu-distro-info --devel 2>/dev/null || true)"

out=()
for series in $supported; do
  if [[ -n "$devel" && "$series" == "$devel" ]]; then
    continue
  fi
  out+=("$series")
done

if [[ "${#out[@]}" -eq 0 ]]; then
  echo "No publishable Ubuntu series resolved from ubuntu-distro-info --supported" >&2
  exit 1
fi

printf '%s\n' "${out[*]}"
