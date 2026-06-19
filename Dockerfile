FROM --platform=linux/amd64 debian:trixie-slim

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_MIRROR=http://chinanet.mirrors.ustc.edu.cn/debian
ARG DEBIAN_SECURITY_MIRROR=http://chinanet.mirrors.ustc.edu.cn/debian-security
ARG PROXMOX_MIRROR=https://chinanet.mirrors.ustc.edu.cn/proxmox
ARG PROXMOX_SUITE=trixie
ARG PROXMOX_KEYRING_VERSION=4.0
ARG INSTALL_ALL_PROXMOX_DEVEL_PACKAGES=true
ARG USERNAME=pve
ARG USER_UID=1000
ARG USER_GID=1000

ENV LANG=C.UTF-8

RUN printf '%s\n' \
        'Types: deb' \
        "URIs: ${DEBIAN_MIRROR}" \
        "Suites: ${PROXMOX_SUITE} ${PROXMOX_SUITE}-updates" \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        '' \
        'Types: deb' \
        "URIs: ${DEBIAN_SECURITY_MIRROR}" \
        "Suites: ${PROXMOX_SUITE}-security" \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/debian.sources

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gzip \
    && rm -rf /var/lib/apt/lists/*

RUN keyring_deb="/tmp/proxmox-archive-keyring_${PROXMOX_KEYRING_VERSION}_all.deb" \
    && curl -fsSL \
        "${PROXMOX_MIRROR}/debian/devel/dists/${PROXMOX_SUITE}/main/binary-amd64/proxmox-archive-keyring_${PROXMOX_KEYRING_VERSION}_all.deb" \
        -o "${keyring_deb}" \
    && dpkg -i "${keyring_deb}" \
    && rm -f "${keyring_deb}"

RUN printf '%s\n' \
        'Package: *' \
        'Pin: release o=Proxmox' \
        'Pin-Priority: 1001' \
        > /etc/apt/preferences.d/proxmox-devel \
    && printf '%s\n' \
        'Types: deb' \
        "URIs: ${PROXMOX_MIRROR}/debian/devel/" \
        "Suites: ${PROXMOX_SUITE}" \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/proxmox-devel.sources

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
    && if [[ "${INSTALL_ALL_PROXMOX_DEVEL_PACKAGES}" == "true" ]]; then \
        curl -fsSL "${PROXMOX_MIRROR}/debian/devel/dists/${PROXMOX_SUITE}/main/binary-amd64/Packages.gz" \
            | gzip -dc \
            | awk '/^Package: / { print $2 }' \
            | sort -u \
            > /tmp/proxmox-devel-packages; \
        apt-get install -y --no-install-recommends $(cat /tmp/proxmox-devel-packages); \
        rm -f /tmp/proxmox-devel-packages; \
    fi \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
    && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USERNAME}" > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}
WORKDIR /workspaces/pve

CMD ["/bin/bash"]
