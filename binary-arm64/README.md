# PVE ARM64/RISCV64 Builder

This repository builds Proxmox VE Debian packages for Debian trixie on `arm64`
and `riscv64`. The build container itself runs on `amd64` and uses Debian
cross-building toolchains.

## Build The Container

Run this inside the repository directory.

```bash
docker build -t pve-arm64-builder:trixie .
```

Run the container in the background. The parent directory of this repository is
mounted at `/workspaces/pve`, so the repository path inside the container is
`/workspaces/pve/pve-arm64-builder`.

```bash
docker run -d --name pve-arm64-builder \
  -v "$(dirname "$PWD"):/workspaces/pve" \
  -w /workspaces/pve \
  pve-arm64-builder:trixie \
  sleep infinity
```

Enter the container when manual inspection is needed.

```bash
docker exec -it pve-arm64-builder bash
```

## Build ARM64

Build all supported Proxmox VE packages for `arm64`.

```bash
docker exec pve-arm64-builder bash -lc \
  '/workspaces/pve/pve-arm64-builder/build_pve_arm64.sh'
```

Artifacts and logs:

```text
../out/arm64/
../logs/pve-arm64/
```

## Build RISCV64

Build all supported Proxmox VE packages for `riscv64`.

```bash
docker exec pve-arm64-builder bash -lc \
  '/workspaces/pve/pve-arm64-builder/build_pve_riscv64.sh'
```

Artifacts and logs:

```text
../out/riscv64/
../logs/pve-riscv64/
```

## Build Options

Rebuild only selected source packages. This is useful after changing a patch or
fixing one package.

```bash
docker exec pve-arm64-builder bash -lc \
  'ONLY_SOURCES="qemu-server lxc-pve" MAX_PASSES=1 RESUME_BUILT=0 \
   /workspaces/pve/pve-arm64-builder/build_pve_riscv64.sh'
```

Common environment variables:

```text
ONLY_SOURCES   Space or comma separated source package list.
MAX_PASSES     Build retry passes. Default: 4.
RESUME_BUILT   Reuse LOG_DIR/built.txt when set to 1. Default: 1.
OUT_DIR        Override output directory.
LOG_DIR        Override log directory.
PATCH_DIR      Override patch directory. Default: pve-arm64-builder/patches.
```

## Local Patches

Patches are loaded recursively from `patches/`. A patch is applied when its
filename matches one of these patterns:

```text
<source>.patch
<source>-*.patch
<repo-name>.patch
<repo-name>-*.patch
```

The current patch set includes QEMU target extensions for `riscv64` and
`loongarch64`, plus fixes for non-x86 Proxmox VE runtime issues found during
testing.

## APT Repository

Each build refreshes a flat apt repository:

```text
../out/arm64/Packages
../out/arm64/Packages.gz
../out/riscv64/Packages
../out/riscv64/Packages.gz
```

Use a local file source on the build host.

```bash
echo "deb [trusted=yes arch=arm64] file:$(dirname "$PWD")/out/arm64 ./" \
  | sudo tee /etc/apt/sources.list.d/pve-arm64-local.list

echo "deb [trusted=yes arch=riscv64] file:$(dirname "$PWD")/out/riscv64 ./" \
  | sudo tee /etc/apt/sources.list.d/pve-riscv64-local.list

sudo apt update
```

Serve the repository over HTTP for a target machine.

```bash
cd "$(dirname "$PWD")/out/riscv64"
python3 -m http.server 8080
```

Add the HTTP repository on the target machine. Replace the architecture and URL
as needed.

```bash
echo 'deb [trusted=yes arch=riscv64] http://BUILD_HOST:8080 ./' \
  | sudo tee /etc/apt/sources.list.d/pve-riscv64-local.list
sudo apt update
```

## Install

The target system should be Debian trixie or based on Debian trixie. Networking
should be managed by `ifupdown2`, not `systemd-networkd`, NetworkManager or
netplan. The host name should resolve to a non-loopback address or to
`127.0.1.1`.

```bash
sudo apt install proxmox-ve
```

If a package was rebuilt with the same version, clear apt's cache before
reinstalling.

```bash
sudo apt clean
sudo apt update
sudo apt install --reinstall qemu-server lxc-pve pve-manager
```

## Notes

- `proxmox-ve`, `pve-manager` and `libpve-storage-perl` dependency metadata is
  relaxed for the no-kernel/no-ZFS/no-Ceph build.
- Ceph/RBD/CephFS paths are kept optional. Install the relevant Ceph packages if
  those features are required.
- `pve-qemu-kvm` for `riscv64` includes the `qemu-system-riscv64` target.
- `lxc-pve` must be built with AppArmor support; the scripts pin the cross
  `libapparmor-dev` dependency to match the native build architecture package.

## Clean Rebuild

Remove outputs and logs before a clean rebuild.

```bash
rm -rf ../out/arm64 ../logs/pve-arm64
rm -rf ../out/riscv64 ../logs/pve-riscv64
```

## Acknowledgements

Thanks to [@YooLc](https://github.com/yoolc) for providing test hardware and
helping promote the project.
