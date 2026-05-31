# PVE ARM64 Builder

这个目录用于构建 Debian trixie 上的 Proxmox VE arm64 deb 包。容器本身是 amd64，使用交叉构建生成 arm64 包。

## 构建开发容器

在 `pve-arm64-builder` 仓库目录内执行：

```bash
docker build -t pve-arm64-builder:trixie .
```

后台运行容器，并把 `pve-arm64-builder` 的父目录挂载到 `/workspaces/pve`：

```bash
docker run -d --name pve-arm64-builder \
  -v "$(dirname "$PWD"):/workspaces/pve" \
  -w /workspaces/pve \
  pve-arm64-builder:trixie \
  sleep infinity
```

进入容器：

```bash
docker exec -it pve-arm64-builder bash
```

## 构建 PVE arm64 包

```bash
docker exec pve-arm64-builder bash -lc '/workspaces/pve/pve-arm64-builder/build_pve_arm64.sh'
```

输出目录：

```text
out/arm64
```

脚本会拉取源码、排除 kernel/zfs/ceph 相关组件、构建 arm64 deb，并生成 flat apt 源索引：

```text
out/arm64/Packages
out/arm64/Packages.gz
```

## 使用生成的 apt 源

本机文件源：

```bash
echo "deb [trusted=yes arch=arm64] file:$(dirname "$PWD")/out/arm64 ./" \
  | sudo tee /etc/apt/sources.list.d/pve-arm64-local.list
sudo apt update
```

HTTP 源：

```bash
cd "$(dirname "$PWD")/out/arm64"
python3 -m http.server 8080
```

目标机添加：

```bash
echo 'deb [trusted=yes arch=arm64] http://BUILD_HOST:8080 ./' \
  | sudo tee /etc/apt/sources.list.d/pve-arm64-local.list
sudo apt update
```

## 安装

请确保当前系统：

- 为或基于 debian trixie
- 使用 ifupdown2 管理网络（不能使用 systemd-networkd/NetworkManager/netplan）
- 能够将主机名解析为 127.0.0.1 之外的地址（如内网地址或 127.0.1.1）

```bash
sudo apt install proxmox-ve
```

## 说明

- Debian trixie 和 Proxmox devel trixie 源使用 ZJU mirror。
- `proxmox-ve`、`pve-manager`、`libpve-storage-perl` 中的 kernel/zfs/ceph/librados 相关依赖已按当前 arm64 无内核组件方案放宽。
- 若后续真的使用 Ceph/RBD/CephFS，需要额外安装对应 Ceph 包。
- 重新构建前可删除 `out/arm64` 和 `logs/pve-arm64` 做 clean rebuild。
