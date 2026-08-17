# Unofficial Bambu Studio Ubuntu PPA

Launchpad packaging for Bambu Studio on Ubuntu.

This repository maintains the source package, automation, and release flow behind `ppa:daddyparodz/bambustudio`.

Current publishable Ubuntu series:

- `jammy` (22.04 LTS)
- `noble` (24.04 LTS)
- `resolute` (26.04 LTS)

The release workflow derives its target series from `ubuntu-distro-info --supported` and excludes the active development series. This lets supported releases move forward automatically as Ubuntu support status changes.

## Install Stable

```bash
sudo add-apt-repository ppa:daddyparodz/bambustudio
sudo apt update
sudo apt install bambustudio
```

## Install Beta

```bash
sudo add-apt-repository ppa:daddyparodz/bambustudio
sudo apt update
sudo apt install bambustudio-beta
```

## Install Both Side-by-Side

```bash
sudo add-apt-repository ppa:daddyparodz/bambustudio
sudo apt update
sudo apt install bambustudio bambustudio-beta
```

## What You Get

- `bambustudio`: stable channel package
- `bambustudio-beta`: beta channel package
- side-by-side install support
- desktop launcher integration
- updates delivered via normal `apt upgrade`

## Verify Installed Versions

```bash
apt-cache policy bambustudio
apt-cache policy bambustudio-beta
```

## Update

```bash
sudo apt update
sudo apt upgrade
```

## Remove

```bash
sudo apt remove bambustudio
sudo apt remove bambustudio-beta
sudo add-apt-repository --remove ppa:daddyparodz/bambustudio
```

## Launch

```bash
bambustudio
bambustudio-beta
gtk-launch bambustudio
gtk-launch bambustudio-beta
```

## CI Runner Fallback

GitHub Actions prefers the standard GitHub-hosted `ubuntu-latest` runner. If that attempt finishes without success, the workflow retries the same validation or release channel on a Linux x64 self-hosted runner inside a clean `ubuntu:24.04` job container.

Both runner paths install and verify the build, packaging, signing, Launchpad, SSH, and GitHub CLI dependencies needed by the workflow. The self-hosted host therefore only needs the runner application and Docker, not the Debian packaging toolchain itself.

Self-hosted fallback requirements:

- GitHub Actions runner `v2.327.1` or newer for `actions/checkout@v5`
- default runner labels `self-hosted`, `linux`, and `x64`
- Docker installed and usable by the runner service account
- outbound network access required for GitHub, Ubuntu package mirrors, upstream Bambu Studio release assets, Docker Hub, and Launchpad
- if the runner application itself is containerized, it must have access to a Docker daemon capable of starting GitHub Actions job containers

The validation workflow does not execute fork-originated pull requests on self-hosted infrastructure. Same-repository pull requests can fall back to the self-hosted container when the GitHub-hosted validation attempt fails.

PPA sync fallback is isolated per channel. If the GitHub-hosted stable job succeeds but beta fails, only beta is retried on self-hosted infrastructure. This avoids an unnecessary duplicate release of the successful channel.

## Release Cadence

The PPA checks upstream releases automatically every 6 hours and publishes:

- latest stable to `bambustudio`
- latest beta to `bambustudio-beta`

Packaging and release-automation changes pushed to `main` also run the sync immediately, so validated packaging changes do not have to wait for the next six-hour poll.

## Known Issues

- On native Wayland sessions (Ubuntu default), BambuStudio may show both its in-app top bar controls and compositor-managed window controls. This behavior comes from upstream app/compositor decoration handling and is not reliably patchable from Debian packaging alone.

## Upstream

Upstream project and release source:

- <https://github.com/bambulab/BambuStudio>
- <https://github.com/bambulab/BambuStudio/releases>

