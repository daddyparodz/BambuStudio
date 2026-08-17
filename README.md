# Unofficial Bambu Studio Ubuntu PPA

Launchpad packaging for Bambu Studio on Ubuntu.

This repository maintains the source package, automation, and release flow behind `ppa:daddyparodz/bambustudio`.

Supported Ubuntu series:

- `jammy` (22.04 LTS)
- `noble` (24.04 LTS)
- `questing` (25.10)

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

## Self-Hosted CI Runner

GitHub Actions jobs run on a Linux x64 self-hosted runner and execute inside a clean `ubuntu:24.04` job container. The workflows install and verify their build, packaging, signing, Launchpad, SSH, and GitHub CLI dependencies inside the job container before checkout, so those tools do not need to be installed on the runner host.

Runner requirements:

- GitHub Actions runner `v2.327.1` or newer for `actions/checkout@v5`
- default runner labels `self-hosted`, `linux`, and `x64`
- Docker installed and usable by the runner service account
- outbound network access required for GitHub, Ubuntu package mirrors, upstream Bambu Studio release assets, Docker Hub, and Launchpad
- if the runner application itself is containerized, it must have access to a Docker daemon capable of starting GitHub Actions job containers

The validation workflow does not run fork-originated pull requests on the self-hosted runner. This avoids executing untrusted fork code on self-hosted infrastructure in this public repository. Same-repository pull requests, pushes to `main`, and manual validation runs use the self-hosted container.

## Release Cadence

The PPA checks upstream releases automatically every 6 hours and publishes:

- latest stable to `bambustudio`
- latest beta to `bambustudio-beta`

## Known Issues

- On native Wayland sessions (Ubuntu default), BambuStudio may show both its in-app top bar controls and compositor-managed window controls. This behavior comes from upstream app/compositor decoration handling and is not reliably patchable from Debian packaging alone.

## Upstream

Upstream project and release source:

- <https://github.com/bambulab/BambuStudio>
- <https://github.com/bambulab/BambuStudio/releases>

