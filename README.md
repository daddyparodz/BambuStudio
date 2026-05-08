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

## Maintainers

This repository contains the Debian packaging, Launchpad upload workflow, and release automation used to publish the PPA.
