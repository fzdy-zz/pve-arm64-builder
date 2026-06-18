FROM --platform=linux/amd64 debian:trixie-slim

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG INSTALL_ALL_PROXMOX_DEVEL_PACKAGES=true
ARG USERNAME=pve
ARG USER_UID=1000
ARG USER_GID=1000

ENV LANG=C.UTF-8

# 1. 优先使用原生基本源，安装 apt-transport-https 与 ca-certificates
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gzip \
    && rm -rf /var/lib/apt/lists/*

# 2. 此时系统已具备全量 HTTPS 校验能力，将所有源变更为强制 HTTPS 协议
RUN printf '%s\n' \
        'Types: deb' \
        'URIs: https://debian.org' \
        'Suites: trixie trixie-updates' \
        'Components: main contrib non-free-firmware' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        '' \
        'Types: deb' \
        'URIs: https://debian.org' \
        'Suites: trixie-security' \
        'Components: main contrib non-free-firmware' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/debian.sources

# 3. 通过安全的 HTTPS 链路下载 Proxmox 官方 GPG 密钥
RUN curl -fsSL https://proxmox.com \
        -o /usr/share/keyrings/proxmox-archive-keyring.gpg

# 4. 配置 Proxmox 官方开发源与无订阅源，并强制全部走 HTTPS 链接
RUN printf '%s\n' \
        'Package: *' \
        'Pin: release o=Proxmox' \
        'Pin-Priority: 1001' \
        > /etc/apt/preferences.d/proxmox-devel \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://proxmox.com' \
        'Suites: trixie' \
        'Components: pve-no-subscription' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        '' \
        'Types: deb' \
        'URIs: https://proxmox.com' \
        'Suites: trixie' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/proxmox.sources

# 5. 更新 HTTPS 软件源并安装编译开发环境，根据参数自动解析并下载所有 Proxmox 研发包
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-utils \
        bash-completion \
        build-essential \
        debhelper \
        devscripts \
        dh-make \
        equivs \
        fakeroot \
        file \
        git \
        less \
        lintian \
        locales \
        make \
        man-db \
        pkg-config \
        quilt \
        rsync \
        sudo \
        vim-tiny \
    && if [ "${INSTALL_ALL_PROXMOX_DEVEL_PACKAGES}" = "true" ]; then \
        curl -fsSL "https://proxmox.com/dists/trixie/main/binary-amd64/Packages.gz" \
            | gzip -dc \
            | awk '/^Package: / { print $2 }' \
            | sort -u \
            > /tmp/proxmox-devel-packages; \
        apt-get install -y --no-install-recommends $(cat /tmp/proxmox-devel-packages); \
        rm -f /tmp/proxmox-devel-packages; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# 6. 配置普通开发用户与 sudo 免密权限
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
    && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USERNAME}" > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}
WORKDIR /workspaces/pve

CMD ["/bin/bash"]
