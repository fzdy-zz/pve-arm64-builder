FROM --platform=linux/amd64 debian:trixie-slim

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG INSTALL_ALL_PROXMOX_DEVEL_PACKAGES=true
ARG USERNAME=pve
ARG USER_UID=1000
ARG USER_GID=1000

ENV LANG=C.UTF-8

# 1. 配置 Debian 官方原生系统的 DEB822 格式源
RUN printf '%s\n' \
        'Types: deb' \
        'URIs: http://deb.debian.org/debian' \
        'Suites: trixie trixie-updates' \
        'Components: main contrib non-free-firmware' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        '' \
        'Types: deb' \
        'URIs: http://security.debian.org/debian-security' \
        'Suites: trixie-security' \
        'Components: main contrib non-free-firmware' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/debian.sources

# 2. 安装基础工具并下载 Proxmox 官方 GPG 密钥
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gzip \
    && curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && rm -rf /var/lib/apt/lists/*

# 3. 配置 Proxmox 官方开发与无订阅(No-Subscription)源
RUN printf '%s\n' \
        'Package: *' \
        'Pin: release o=Proxmox' \
        'Pin-Priority: 1001' \
        > /etc/apt/preferences.d/proxmox-devel \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: http://download.proxmox.com/debian/pve' \
        'Suites: trixie' \
        'Components: pve-no-subscription' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        '' \
        'Types: deb' \
        'URIs: http://proxmox.com' \
        'Suites: trixie' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/proxmox.sources

# 4. 安装编译/开发环境，并根据参数拉取所有 Proxmox 研发包
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
        curl -fsSL "http://proxmox.com/dists/trixie/main/binary-amd64/Packages.gz" \
            | gzip -dc \
            | awk '/^Package: / { print $2 }' \
            | sort -u \
            > /tmp/proxmox-devel-packages; \
        apt-get install -y --no-install-recommends $(cat /tmp/proxmox-devel-packages); \
        rm -f /tmp/proxmox-devel-packages; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# 5. 配置普通开发用户与 sudo 权限
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
    && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USERNAME}" > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}
WORKDIR /workspaces/pve

CMD ["/bin/bash"]
