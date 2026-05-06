# Bambu Studio Ubuntu PPA

Launchpad packaging for Bambu Studio on Ubuntu.

This repository maintains the source package, automation, and release flow behind `ppa:daddyparodz/bambustudio`.

Supported Ubuntu series:

- `jammy` (22.04 LTS)
- `noble` (24.04 LTS)
- `questing` (25.10)

## Install

```bash
sudo add-apt-repository ppa:daddyparodz/bambustudio
sudo apt update
sudo apt install bambustudio
```

## Included

- Ubuntu packages built from the official Bambu Lab Linux releases
- Desktop integration for launching `bambustudio` as a standard application
- Updates delivered through normal `apt` upgrades

## Update

```bash
sudo apt update
sudo apt upgrade
```

## Remove

```bash
sudo apt remove bambustudio
sudo add-apt-repository --remove ppa:daddyparodz/bambustudio
```

## Upstream

Upstream project and release source:

- <https://github.com/bambulab/BambuStudio>
- <https://github.com/bambulab/BambuStudio/releases>

## Maintainers

This repository contains the Debian packaging, Launchpad upload workflow, and release automation used to publish the PPA.
