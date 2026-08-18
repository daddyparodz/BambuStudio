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

## Self-Hosted CI Runner

All GitHub Actions validation and PPA release jobs run only on a Linux x64 self-hosted runner with the default labels `self-hosted`, `linux`, and `x64`. Each job executes inside a clean `ubuntu:24.04` GitHub Actions job container.

The workflows install and verify their build, packaging, signing, Launchpad, SFTP/SSH, and GitHub CLI dependencies inside the job container. The runner host therefore only needs the GitHub Actions runner and Docker, not the Debian packaging toolchain itself.

Runner requirements:

- GitHub Actions runner `v2.327.1` or newer for `actions/checkout@v5`
- default runner labels `self-hosted`, `linux`, and `x64`
- Docker installed and usable by the runner service account
- outbound network access required for GitHub, Ubuntu package mirrors, upstream Bambu Studio release assets, Docker Hub, and Launchpad
- if the runner application itself is containerized, it must have access to a Docker daemon capable of starting GitHub Actions job containers

Fork-originated pull requests are not executed on self-hosted infrastructure. Same-repository pull requests run the full packaging validation plus non-uploading stable and beta PPA dry runs on the self-hosted container runner.

## PPA Retention and Release Safety

The pruning policy keeps the newest published source for each package and each Ubuntu series independently. It does not delete the newest Jammy or Noble source just because a newer Resolute publication exists. This preserves the per-series orig tarballs required by later Debian revision uploads.

Revision releases reuse the exact historical orig tarball. If an earlier retention run removed that file from the public PPA pool, the release helper searches all Launchpad source-publication states, follows paginated history, and recovers the retained Librarian copy. If Launchpad history cannot be queried completely or an existing orig cannot be recovered exactly, the release fails instead of regenerating a potentially different file under the same upstream filename.

Production uploads no longer keep the self-hosted runner occupied while Launchpad builds packages. Immediately before `dput`, the workflow records an exact `state/pending-<channel>.json` manifest on the dedicated `release-state` branch. The manifest contains the upstream tag, repository commit, PPA revision, and exact source version expected for every Ubuntu series. A later sync sees the pending state and will not upload another revision for that channel.

The separate `Verify Launchpad PPA Publications` workflow runs every 10 minutes. Each run performs one Launchpad status check and exits immediately. If sources or builds are still pending, it leaves the manifest unchanged. When all expected builds succeed, it promotes the pending manifest to the authoritative `state/latest-*-*.txt` markers and removes the pending state. A terminal Launchpad build failure is recorded once as `state/failed-<channel>.json`; the same release is not retried automatically until the upstream tag or release inputs change. If an upload reached Launchpad but its pending bookkeeping was lost, the sync can recover the existing historical revision as pending instead of uploading a duplicate.

A source that never becomes visible on Launchpad is treated as failed after 30 minutes. Temporary Launchpad API errors are treated as pending and retried by the next verifier run rather than holding a runner open.

The `state/latest-*-*.txt` files on `main` are legacy snapshots and are not used for release decisions. The authoritative stable and beta verified markers, pending manifests, and failure records live on `release-state`.

## Release Cadence

The PPA checks upstream releases automatically every 6 hours and publishes:

- latest stable to `bambustudio`
- latest beta to `bambustudio-beta`

Packaging and release-automation changes pushed to `main` also run the sync immediately, so validated packaging changes do not have to wait for the next six-hour poll. Launchpad verification is decoupled from that cadence and runs independently every 10 minutes while consuming the runner only for a short status check.

## Known Issues

- On native Wayland sessions (Ubuntu default), BambuStudio may show both its in-app top bar controls and compositor-managed window controls. This behavior comes from upstream app/compositor decoration handling and is not reliably patchable from Debian packaging alone.

## Upstream

Upstream project and release source:

- <https://github.com/bambulab/BambuStudio>
- <https://github.com/bambulab/BambuStudio/releases>
