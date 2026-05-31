#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${ROOT:-/workspaces/pve}
SRC_DIR=${SRC_DIR:-${ROOT}/src}
OUT_DIR=${OUT_DIR:-${ROOT}/out/arm64}
LOG_DIR=${LOG_DIR:-${ROOT}/logs/pve-arm64}
PLAN_FILE=${PLAN_FILE:-${ROOT}/pve-devcontainer/pve-source-plan.txt}
PLAN_SCRIPT=${PLAN_SCRIPT:-${ROOT}/pve-devcontainer/plan_pve_sources.py}
RELAX_DEPS_SCRIPT=${RELAX_DEPS_SCRIPT:-${ROOT}/pve-devcontainer/relax_pve_dependencies.py}
MAX_PASSES=${MAX_PASSES:-4}
JOBS=${JOBS:-$(nproc)}
BUILD_ARCH=${BUILD_ARCH:-amd64}
HOST_ARCH=${HOST_ARCH:-arm64}
PROXMOX_GIT_BASE=${PROXMOX_GIT_BASE:-https://git.proxmox.com/git}

if [[ "$(id -u)" == 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

run_root() {
    "${SUDO[@]}" "$@"
}

mkdir -p "${SRC_DIR}" "${OUT_DIR}" "${LOG_DIR}"

exec 9>"${ROOT}/.pve-arm64-build.lock"
if ! flock -n 9; then
    log "another pve arm64 build is already running"
    exit 1
fi

refresh_local_repo() {
    prune_excluded_binary_artifacts
    (
        cd "${OUT_DIR}"
        if compgen -G '*.deb' >/dev/null; then
            dpkg-scanpackages --multiversion . /dev/null > Packages
        else
            : > Packages
        fi
        gzip -9c < Packages > Packages.gz
        chmod a+r Packages Packages.gz
    )
    printf '%s\n' "deb [trusted=yes] file:${OUT_DIR} ./" \
        | run_root tee /etc/apt/sources.list.d/local-pve-arm64.list >/dev/null
    run_root apt-get -o APT::Sandbox::User=root update
}

prepare_apt() {
    log "preparing apt and cross-build tools"
    if ! dpkg --print-foreign-architectures | grep -qx "${HOST_ARCH}"; then
        run_root dpkg --add-architecture "${HOST_ARCH}"
    fi

    run_root apt-get -o APT::Sandbox::User=root update
    run_root apt-get install -y --no-install-recommends \
        autoconf \
        autoconf-archive \
        automake \
        bison \
        cargo \
        cmake \
        crossbuild-essential-arm64 \
        curl \
        dc \
        debcargo \
        debhelper \
        devscripts \
        dh-python \
        doxygen \
        doxygen2man \
        dpkg-dev \
        equivs \
        fakeroot \
        flex \
        g++-aarch64-linux-gnu \
        gcc-aarch64-linux-gnu \
        git \
        graphviz \
        jq \
        librust-cidr-dev \
        librust-crossbeam-channel-dev \
        librust-pam-sys-dev \
        librust-proxmox-docgen-dev \
        librust-proxmox-ldap-dev \
        librust-proxmox-metrics-dev \
        librust-proxmox-openid-dev \
        librust-proxmox-parallel-handler-dev \
        librust-proxmox-rest-server-dev \
        librust-proxmox-rrd-dev \
        librust-proxmox-upgrade-checks-dev \
        librust-udev-dev \
        python3-sphinx \
        python3-sphinx-rtd-theme \
        python3-venv \
        lz4 \
        meson \
        ninja-build \
        pkgconf \
        pve-doc-generator \
        proxmox-wasm-builder \
        python3 \
        python3-pip \
        python3-pip-whl \
        python3-pycotap \
        python3-setuptools \
        python3-wheel \
        python3-wheel-whl \
        quilt \
        rsync \
        rustc \
        rustfmt \
        xz-utils \
        zstd

    run_root apt-get install -y --no-install-recommends \
        "python3:${BUILD_ARCH}"

    run_root apt-get install -y --no-install-recommends \
        "check:${HOST_ARCH}" \
        "libapt-pkg-dev:${HOST_ARCH}" \
        "libacl1-dev:${HOST_ARCH}" \
        "libasound2-dev:${HOST_ARCH}" \
        "libcurl4-gnutls-dev:${HOST_ARCH}" \
        "libepoxy-dev:${HOST_ARCH}" \
        "libfdt-dev:${HOST_ARCH}" \
        "libfuse3-dev:${HOST_ARCH}" \
        "libgbm-dev:${HOST_ARCH}" \
        "libglib2.0-dev:${HOST_ARCH}" \
        "libiscsi-dev:${HOST_ARCH}" \
        "libnetfilter-conntrack-dev:${HOST_ARCH}" \
        "libnetfilter-log-dev:${HOST_ARCH}" \
        "libnspr4-dev:${HOST_ARCH}" \
        "libnss3-dev:${HOST_ARCH}" \
        "libnuma-dev:${HOST_ARCH}" \
        "libpam0g-dev:${HOST_ARCH}" \
        "liburing-dev:${HOST_ARCH}" \
        "libvirglrenderer-dev:${HOST_ARCH}" \
        "librrd-dev:${HOST_ARCH}" \
        "libsasl2-dev:${HOST_ARCH}" \
        "libsgutils2-dev:${HOST_ARCH}" \
        "libslirp-dev:${HOST_ARCH}" \
        "libsnappy-dev:${HOST_ARCH}" \
        "libssl-dev:${HOST_ARCH}" \
        "libsqlite3-dev:${HOST_ARCH}" \
        "libsnmp-dev:${HOST_ARCH}" \
        "libsystemd-dev:${HOST_ARCH}" \
        "libudev-dev:${HOST_ARCH}" \
        "libusb-1.0-0-dev:${HOST_ARCH}" \
        "libusbredirparser-dev:${HOST_ARCH}" \
        "libxkbcommon-dev:${HOST_ARCH}" \
        "libyang-dev:${HOST_ARCH}"

    if [[ ! -x "${HOME}/.cargo/bin/rustup" ]]; then
        log "installing rustup for the aarch64 Rust target"
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    export CARGO_HOME="${HOME}/.cargo"
    export RUSTUP_HOME="${HOME}/.rustup"
    export PATH="${CARGO_HOME}/bin:${PATH}"
    rustup toolchain install stable --profile minimal --target aarch64-unknown-linux-gnu --target wasm32-unknown-unknown
    rustup component add rustfmt --toolchain stable
    rustup default stable

    refresh_local_repo
}

source_to_repo() {
    case "$1" in
        corosync) printf '%s\n' corosync-pve ;;
        libjs-extjs) printf '%s\n' extjs ;;
        libproxmox-acme) printf '%s\n' proxmox-acme ;;
        libproxmox-rs-perl) printf '%s\n' proxmox-perl-rs ;;
        libpve-access-control) printf '%s\n' pve-access-control ;;
        libpve-apiclient-perl) printf '%s\n' pve-apiclient ;;
        libpve-common-perl) printf '%s\n' pve-common ;;
        libpve-guest-common-perl) printf '%s\n' pve-guest-common ;;
        libpve-http-server-perl) printf '%s\n' pve-http-server ;;
        libpve-network-perl) printf '%s\n' pve-network ;;
        libpve-rs-perl) printf '%s\n' proxmox-perl-rs ;;
        libpve-storage-perl) printf '%s\n' pve-storage ;;
        lvm2) printf '%s\n' lvm ;;
        lxc-pve) printf '%s\n' lxc ;;
        proxmox-enterprise-support-keyring) printf '%s\n' proxmox-enterprise-support ;;
        proxmox-termproxy) printf '%s\n' pve-xtermjs ;;
        pve-nvidia-vgpu-helper) printf '%s\n' pve-vgpu-helper ;;
        pve-qemu-kvm) printf '%s\n' pve-qemu ;;
        pve-yew-mobile-gui) printf '%s\n' ui/pve-yew-mobile-gui ;;
        rust-proxmox-backup) printf '%s\n' proxmox-backup ;;
        rust-proxmox-mail-forward) printf '%s\n' proxmox-mail-forward ;;
        rust-proxmox-offline-mirror) printf '%s\n' proxmox-offline-mirror ;;
        rust-proxmox-websocket-tunnel) printf '%s\n' proxmox-websocket-tunnel ;;
        *) printf '%s\n' "$1" ;;
    esac
}

is_excluded_source() {
    case "$1" in
        *ceph*|*rados*|*rbd*|*zfs*|zfsonlinux|*kernel*|*headers*|pve-firmware|proxmox-backup-restore-image)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_excluded_binary() {
    case "$1" in
        *ceph*|*rados*|*rbd*|*zfs*|zfsonlinux|*kernel*|*headers*|pve-firmware|proxmox-backup-restore-image)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

prune_excluded_binary_artifacts() {
    local deb package
    for deb in "${OUT_DIR}"/*.deb; do
        [[ -e "${deb}" ]] || continue
        package=$(dpkg-deb -f "${deb}" Package 2>/dev/null || true)
        if [[ -n "${package}" ]] && is_excluded_binary "${package}"; then
            log "removing excluded binary artifact ${package}: $(basename "${deb}")"
            rm -f "${deb}"
        fi
    done
}

source_ref() {
    case "$1" in
        qemu-server)
            # Pin to the 9.1.16 changelog bump. The current master has
            # unreleased dependency changes but still carries version 9.1.16.
            printf '%s\n' 02ba5c110a0c82acbfbf58c91350a0eb24ded686
            ;;
    esac
}

repo_url() {
    printf '%s/%s.git\n' "${PROXMOX_GIT_BASE}" "$1"
}

clone_or_update_git_source() {
    local source=$1
    local repo=$2
    local dir="${SRC_DIR}/${repo//\//__}"
    local url ref
    url=$(repo_url "${repo}")
    ref=$(source_ref "${source}" || true)

    if [[ ! -d "${dir}/.git" ]]; then
        log "cloning ${source} from ${url}"
        if [[ -n "${ref}" ]]; then
            git clone --recursive "${url}" "${dir}"
        else
            git clone --recursive --depth=1 "${url}" "${dir}"
        fi
    else
        log "updating ${source} in ${dir}"
        git -C "${dir}" fetch --all --tags --prune
        if [[ -z "${ref}" ]]; then
            git -C "${dir}" pull --ff-only || true
        fi
        git -C "${dir}" submodule update --init --recursive || true
    fi

    if [[ -n "${ref}" ]]; then
        if ! git -C "${dir}" cat-file -e "${ref}^{commit}" 2>/dev/null; then
            git -C "${dir}" fetch --deepen=200 origin master || true
        fi
        git -C "${dir}" checkout --detach "${ref}"
        git -C "${dir}" submodule update --init --recursive || true
    fi

    printf '%s\n' "${dir}"
}

extract_package_rebuild_source() {
    local source=$1
    local package_rebuilds="${SRC_DIR}/package-rebuilds"
    local dsc source_tree extracted_dir
    dsc=$(find "${package_rebuilds}/pkgs/${source}" -maxdepth 1 -name '*.dsc' 2>/dev/null | sort -V | tail -1 || true)
    if [[ -z "${dsc}" ]]; then
        return 1
    fi

    local dir="${SRC_DIR}/package-rebuilds-work/${source}"
    rm -rf "${dir}"
    mkdir -p "${dir}"

    source_tree=$(find "${package_rebuilds}/pkgs/${source}" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1 || true)
    extracted_dir=""

    local dsc_base debian_pool_prefix dsc_url
    dsc_base=$(basename "${dsc}")
    if [[ "${source}" == lib* ]]; then
        debian_pool_prefix="${source:0:4}"
    else
        debian_pool_prefix="${source:0:1}"
    fi
    dsc_url="https://mirrors.zju.edu.cn/debian/pool/main/${debian_pool_prefix}/${source}/${dsc_base}"
    (
        cd "${dir}"
        dget -u -x "${dsc_url}"
    ) >/dev/null 2>&1 || true
    extracted_dir=$(find "${dir}" -mindepth 1 -maxdepth 1 -type d | sort -V | head -1 || true)

    if [[ -n "${source_tree}" && -f "${source_tree}/debian/control" ]]; then
        if [[ -z "${extracted_dir}" ]]; then
            extracted_dir="${dir}/$(basename "${source_tree}")"
            mkdir -p "${extracted_dir}"
        fi
        rsync -a "${source_tree}/" "${extracted_dir}/"
    elif [[ -z "${extracted_dir}" ]]; then
        (
            cd "${dir}"
            dpkg-source -x "${dsc}"
        )
    fi

    find "${dir}" -mindepth 1 -maxdepth 1 -type d | head -1
}

source_dir_for() {
    local source=$1
    local repo
    repo=$(source_to_repo "${source}")

    if extract_package_rebuild_source "${source}"; then
        return
    fi

    local dir
    if grep -qx "${repo}.git" "${SRC_DIR}/proxmox-project-index.txt" 2>/dev/null \
        || grep -qx "${repo}.git" "${ROOT}/src/proxmox-project-index.txt" 2>/dev/null; then
        dir=$(clone_or_update_git_source "${source}" "${repo}")
        source_subdir_for "${source}" "${dir}"
        return
    fi

    dir=$(clone_or_update_git_source "${source}" "${repo}")
    source_subdir_for "${source}" "${dir}"
}

source_subdir_for() {
    local source=$1
    local dir=$2

    case "${source}" in
        libproxmox-rs-perl)
            printf '%s\n' "${dir}/common/pkg"
            ;;
        libpve-rs-perl)
            printf '%s\n' "${dir}/pve-rs"
            ;;
        proxmox-enterprise-support-keyring)
            printf '%s\n' "${dir}/support-keyring"
            ;;
        proxmox-termproxy)
            printf '%s\n' "${dir}/termproxy"
            ;;
        pve-xtermjs)
            printf '%s\n' "${dir}/xterm.js"
            ;;
        *)
            printf '%s\n' "${dir}"
            ;;
    esac
}

load_sources() {
    python3 "${PLAN_SCRIPT}" > "${PLAN_FILE}"
    awk '
        $0 == "# source packages" { in_sources = 1; next }
        in_sources && NF { print $1 }
    ' "${PLAN_FILE}" \
        | while read -r source; do
            if ! is_excluded_source "${source}"; then
                printf '%s\n' "${source}"
            fi
        done
}

ordered_sources() {
    local computed=$1
    local order=(
        proxmox-archive-keyring
        fonts-font-logos
        libjs-qrcodejs
        libjs-extjs
        ifupdown2
        libcrypt-openssl-rsa-perl
        rrdtool
        libtpms
        swtpm
        kronosnet
        corosync
        lvm2
        smartmontools
        frr
        apparmor
        lxcfs
        lxc-pve
        proxmox-i18n
        proxmox-widget-toolkit
        libproxmox-acme
        libproxmox-rs-perl
        libpve-common-perl
        libpve-rs-perl
        libpve-apiclient-perl
        pve-cluster
        libpve-access-control
        libpve-http-server-perl
        libpve-guest-common-perl
        libpve-storage-perl
        libpve-network-perl
        pve-lxc-syscalld
        pve-container
        pve-esxi-import-tools
        pve-firewall
        pve-ha-manager
        novnc-pve
        pve-xtermjs
        pve-yew-mobile-gui
        spiceterm
        vncterm
        proxmox-mini-journalreader
        rust-proxmox-mail-forward
        proxmox-termproxy
        proxmox-firewall
        rust-proxmox-websocket-tunnel
        rust-proxmox-backup
        proxmox-backup-qemu
        pve-qemu-kvm
        pve-edk2-firmware
        qemu-server
        pve-nvidia-vgpu-helper
        rust-proxmox-offline-mirror
        pve-docs
        pve-manager
        proxmox-enterprise-support-keyring
        proxmox-ve
    )

    local seen_file="${LOG_DIR}/ordered.seen"
    : > "${seen_file}"

    for source in "${order[@]}"; do
        if grep -qx "${source}" "${computed}"; then
            printf '%s\n' "${source}"
            printf '%s\n' "${source}" >> "${seen_file}"
        fi
    done

    while read -r source; do
        if [[ -n "${source}" ]] && ! grep -qx "${source}" "${seen_file}"; then
            printf '%s\n' "${source}"
        fi
    done < "${computed}"
}

install_build_deps_any_control() {
    local control=$1
    (
        cd "$(dirname "$(dirname "${control}")")"
        run_root mk-build-deps \
            --install \
            --remove \
            --build-dep \
            --build-profiles "nocheck,cross" \
            --host-arch "${HOST_ARCH}" \
            --build-arch "${BUILD_ARCH}" \
            --tool "apt-get -y --allow-downgrades --no-install-recommends -o Debug::pkgProblemResolver=yes -o APT::Sandbox::User=root" \
            "${control}"
    )
}

install_build_deps_any() {
    local dir=$1
    install_build_deps_any_control "${dir}/debian/control"
}

install_build_deps_all_control() {
    local control=$1
    (
        cd "$(dirname "$(dirname "${control}")")"
        run_root mk-build-deps \
            --install \
            --remove \
            --build-profiles "nocheck" \
            --build-arch "${BUILD_ARCH}" \
            --tool "apt-get -y --allow-downgrades --no-install-recommends -o Debug::pkgProblemResolver=yes -o APT::Sandbox::User=root" \
            "${control}"
    )
}

install_build_deps_all() {
    local dir=$1
    install_build_deps_all_control "${dir}/debian/control"
}

control_file_for_dir() {
    local dir=$1
    local control="${dir}/debian/control"

    if [[ -f "${control}" ]]; then
        printf '%s\n' "${control}"
        return 0
    fi

    find "${dir}" -mindepth 2 -maxdepth 3 -path '*/debian/control' -type f \
        | sort \
        | head -1
}

install_wrapper_build_deps() {
    local dir=$1
    local control
    control=$(control_file_for_dir "${dir}")
    local has_arch_any=0

    if [[ -z "${control}" || ! -f "${control}" ]]; then
        return 0
    fi

    if control_has_arch_any_for_host "${control}"; then
        install_build_deps_any_control "${control}"
        has_arch_any=1
    fi

    if [[ "${has_arch_any}" == 0 ]] && control_has_arch_all "${control}"; then
        install_build_deps_all_control "${control}"
    fi
}

cleanup_build_dep_artifacts() {
    local dir=$1

    run_root find "${dir}" "$(dirname "${dir}")" -maxdepth 1 -type f \
        \( -name '*-build-deps_*' -o -name '*-cross-build-deps-*_*' \) \
        -delete
}

reset_git_tree_for_dir() {
    local dir=$1
    local git_root

    git_root=$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -z "${git_root}" ]]; then
        return 0
    fi

    git -C "${git_root}" reset --hard HEAD
    git -C "${git_root}" clean -fdx
    git -C "${git_root}" submodule update --init --recursive || true
}

native_qualify_rust_build_deps() {
    local control=$1

    perl -0pi -e '
        s/^(Build-Depends(?:-[^:]+)?:\s.*?)(?=^\S|\z)/
            my $field = $1;
            $field =~ s#\b(librust-[A-Za-z0-9+_.-]+)(?=\s*(?:\(|,|\n|$))#$1:native#g;
            $field =~ s#\b(cargo|debcargo|dh-cargo|dh-python|esbuild|libstd-rust-dev|mypy|perlmod-bin|proxmox-biome|proxmox-frr-templates|proxmox-wasm-builder|python3|python3-pyvmomi|rust-grass|rust-llvm|rustc|libproxmox-rs-perl)(?=\s*(?:\(|,|\n|$))#$1:native#g;
            $field;
        /egms;
    ' "${control}"
}

control_has_arch_all() {
    awk '
        BEGIN { found = 0 }
        /^Architecture:/ {
            for (i = 2; i <= NF; i++) {
                if ($i == "all") {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

control_has_arch_any_for_host() {
    awk -v host="${HOST_ARCH}" '
        BEGIN { found = 0 }
        /^Architecture:/ {
            for (i = 2; i <= NF; i++) {
                if ($i == "any" || $i == "linux-any" || $i == host) {
                    found = 1
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

skip_arch_all_after_arch_any() {
    case "$1" in
        lvm2)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

move_new_artifacts() {
    local dir=$1
    local stamp=$2
    for artifact_dir in "${dir}" "$(dirname "${dir}")"; do
        find "${artifact_dir}" -maxdepth 1 -type f -newer "${stamp}" \
            \( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) \
            ! -name '*-build-deps_*' \
            -exec mv -f -t "${OUT_DIR}" {} +
    done
}

disable_make_target() {
    local file=$1
    local target=$2
    local tmp
    tmp=$(mktemp)

    awk -v target="${target}" '
        BEGIN { skip = 0 }
        $0 ~ "^" target ":" {
            print
            print "\t:"
            skip = 1
            next
        }
        skip && $0 ~ /^[^[:space:]#][^:]*:/ {
            skip = 0
        }
        !skip { print }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
}

replace_make_targets_with_placeholders() {
    local file=$1
    shift
    local tmp
    tmp=$(mktemp)

    awk -v targets="$*" '
        BEGIN {
            n = split(targets, target_list, " ");
            for (i = 1; i <= n; i++) {
                target_map[target_list[i]] = 1;
            }
        }

        function rule_has_target(line, prefix, parts, count, i) {
            if (line !~ /^[^[:space:]#][^:=]*:/) {
                return 0;
            }
            prefix = line;
            sub(/:.*/, "", prefix);
            count = split(prefix, parts, /[[:space:]]+/);
            for (i = 1; i <= count; i++) {
                if (parts[i] in target_map) {
                    return 1;
                }
            }
            return 0;
        }

        /^-?include \/usr\/share\/pve-doc-generator\/pve-doc-generator.mk/ {
            next;
        }

        {
            if (skip) {
                if ($0 ~ /^[[:space:]]/ || $0 == "") {
                    next;
                }
                skip = 0;
            }
            if (rule_has_target($0)) {
                skip = 1;
                next;
            }
            print;
        }

        END {
            print "";
            print "# cross-build placeholder docs avoid loading local PVE modules.";
            print ".PHONY: cleanup-docgen";
            print "cleanup-docgen:";
            print "\trm -f *.xml.tmp *.1 *.5 *.8 *.adoc docinfo.xml";
            print "\trm -rf generated";

            for (i = 1; i <= n; i++) {
                target = target_list[i];
                if (target == "") {
                    continue;
                }
                print "";
                print target ":";
                if (target ~ /(bash|zsh)-completion$/) {
                    print "\t: > $@";
                } else if (target ~ /^generated\//) {
                    print "\tmkdir -p $(@D)";
                    print "\t: > $@";
                } else {
                    section = "1";
                    name = target;
                    if (target ~ /\.5$/) {
                        section = "5";
                    } else if (target ~ /\.8$/) {
                        section = "8";
                    }
                    sub(/\.[158]$/, "", name);
                    print "\tprintf \".TH " name " " section "\\n.SH NAME\\n" name "\\n\" > $@";
                }
            }
        }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
}

has_proxmox_wrapper() {
    local dir=$1

    if [[ -f "${dir}/GNUmakefile" ]]; then
        return 0
    fi

    if [[ -f "${dir}/Makefile" ]] \
        && grep -qE '^deb([[:space:]][^:]*)?:' "${dir}/Makefile" \
        && grep -q 'dpkg-buildpackage' "${dir}/Makefile"; then
        return 0
    fi

    return 1
}

relax_rbd_plugin_rados_dependency() {
    local file=$1

    [[ -f "${file}" ]] || return 0

    perl -0pi -e '
        s/^use PVE::RADOS;\n//mg;
        s/\bPVE::RADOS->new\(/rados_new(/g;
    ' "${file}"

    if ! grep -q 'sub rados_new' "${file}"; then
        local tmp
        tmp=$(mktemp)
        awk '
            { print }
            /^use PVE::Storage::Common;$/ && !inserted {
                print "";
                print "my sub rados_new {";
                print "    eval { require PVE::RADOS; 1 }";
                print "        or die \"RBD storage requires librados2-perl: $@\";";
                print "    return PVE::RADOS->new(@_);";
                print "}";
                print "";
                inserted = 1;
            }
        ' "${file}" > "${tmp}"
        mv "${tmp}" "${file}"
    fi
    chmod 0644 "${file}"
}

relax_pve_manager_rados_dependency() {
    local dir=$1
    local tools="${dir}/PVE/Ceph/Tools.pm"

    [[ -d "${dir}/PVE" ]] || return 0

    find "${dir}/PVE" -type f -name '*.pm' -print0 \
        | xargs -0 perl -0pi -e '
            s/^use PVE::RADOS;\n//mg;
            s/\bPVE::RADOS->new\(/PVE::Ceph::Tools::rados_new(/g;
        '

    if [[ -f "${tools}" ]]; then
        perl -0pi -e 's/^use PVE::RADOS;\n//mg' "${tools}"

        if ! grep -q 'sub rados_new' "${tools}"; then
            local tmp
            tmp=$(mktemp)
            awk '
                { print }
                /^use PVE::CephConfig;$/ && !inserted {
                    print "";
                    print "sub rados_new {";
                    print "    eval { require PVE::RADOS; 1 }";
                    print "        or die \"Ceph support requires librados2-perl: $@\";";
                    print "    return PVE::RADOS->new(@_);";
                    print "}";
                    print "";
                    inserted = 1;
                }
            ' "${tools}" > "${tmp}"
            mv "${tmp}" "${tools}"
        fi
        chmod 0644 "${tools}"
    fi
}

apply_source_fixes() {
    local source=$1
    local dir=$2

    if [[ -f "${dir}/debian/rules" ]] && grep -q '^override_dh_auto_test:' "${dir}/debian/rules"; then
        disable_make_target "${dir}/debian/rules" 'override_dh_auto_test'
    fi

    if [[ -f "${dir}/debian/control" && -f "${RELAX_DEPS_SCRIPT}" ]]; then
        python3 "${RELAX_DEPS_SCRIPT}" "${dir}/debian/control" || true
    fi

    for makefile in "${dir}/Makefile" "${dir}/GNUmakefile"; do
        if [[ -f "${makefile}" ]] && grep -q 'dpkg-buildpackage' "${makefile}"; then
            perl -0pi -e 's/dpkg-buildpackage(?!\s+-d)\s+/dpkg-buildpackage -d /g' "${makefile}"
        fi
        if [[ -f "${makefile}" ]] && grep -q 'PATH="/usr/local/bin:/usr/bin"' "${makefile}"; then
            sed -i 's#PATH="/usr/local/bin:/usr/bin"#PATH="$(CARGO_HOME)/bin:/usr/local/bin:/usr/bin"#g' "${makefile}"
        fi
        if [[ -f "${makefile}" ]]; then
            sed -i \
                -e 's#^ARCH := $(DEB_BUILD_ARCH)$#ARCH := $(DEB_HOST_ARCH)#' \
                -e 's#^TARGET_DIR=release$#TARGET_DIR=aarch64-unknown-linux-gnu/release#' \
                -e 's#^TARGET_DIR=debug$#TARGET_DIR=aarch64-unknown-linux-gnu/debug#' \
                -e 's#^TARGETDIR := target/release$#TARGETDIR := target/aarch64-unknown-linux-gnu/release#' \
                -e 's#^TARGETDIR := target/debug$#TARGETDIR := target/aarch64-unknown-linux-gnu/debug#' \
                -e 's#^COMPILEDIR := target/release$#COMPILEDIR := target/aarch64-unknown-linux-gnu/release#' \
                -e 's#^COMPILEDIR := target/debug$#COMPILEDIR := target/aarch64-unknown-linux-gnu/debug#' \
                -e 's#target/release/#target/$(TARGET_DIR)/#g' \
                "${makefile}"
        fi
        if [[ -f "${makefile}" ]] && grep -q 'cargo build .*$(CARGO_BUILD_ARGS)' "${makefile}"; then
            sed -i 's#cargo build .*$(CARGO_BUILD_ARGS)#cargo --config '\''build.rustflags=["-C","debuginfo=2","-C","strip=none","--cap-lints","warn"]'\'' build --target aarch64-unknown-linux-gnu $(CARGO_BUILD_ARGS)#g' "${makefile}"
            sed -i \
                -e 's#^TARGET_DIR=release$#TARGET_DIR=aarch64-unknown-linux-gnu/release#' \
                -e 's#^TARGET_DIR=debug$#TARGET_DIR=aarch64-unknown-linux-gnu/debug#' \
                -e 's#^TARGETDIR := target/release$#TARGETDIR := target/aarch64-unknown-linux-gnu/release#' \
                -e 's#^TARGETDIR := target/debug$#TARGETDIR := target/aarch64-unknown-linux-gnu/debug#' \
                -e 's#^COMPILEDIR := target/release$#COMPILEDIR := target/aarch64-unknown-linux-gnu/release#' \
                -e 's#^COMPILEDIR := target/debug$#COMPILEDIR := target/aarch64-unknown-linux-gnu/debug#' \
                -e 's#target/release/#target/$(TARGET_DIR)/#g' \
                "${makefile}"
        fi
        if [[ -f "${makefile}" ]] && grep -qE '^[[:space:]]*lintian[[:space:]]+' "${makefile}"; then
            perl -0pi -e 's/^([ \t]*)lintian\b.*$/$1: # lintian disabled for cross build/mg' "${makefile}"
        fi
    done

    case "${source}" in
        apparmor)
            if [[ -f "${dir}/debian/rules" ]]; then
                sed -i 's#rm \./profiles/apparmor\.d/tunables/xdg-user-dirs\.d/site\.local#rm -f ./profiles/apparmor.d/tunables/xdg-user-dirs.d/site.local#' "${dir}/debian/rules"
            fi
            ;;
        corosync)
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i 's/$(DEB_BUILD_ARCH)/$(DEB_HOST_ARCH)/g' "${dir}/Makefile"
            fi
            ;;
        lxc-pve)
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i 's/$(DEB_BUILD_ARCH)/$(DEB_HOST_ARCH)/g' "${dir}/Makefile"
            fi
            ;;
        libcrypt-openssl-rsa-perl)
            if [[ -f "${dir}/debian/control" ]]; then
                perl -0pi -e 's/\blibcrypt-openssl-guess-perl\b/libcrypt-openssl-guess-perl:native/g' "${dir}/debian/control"
            fi
            ;;
        libpve-rs-perl)
            if [[ -f "${dir}/debian/control" ]]; then
                native_qualify_rust_build_deps "${dir}/debian/control"
            fi
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i \
                    -e 's/DEB_BUILD_ARCH/DEB_HOST_ARCH/g' \
                    -e 's#^PERL_INSTALLVENDORARCH !=.*#PERL_INSTALLVENDORARCH := /usr/lib/$(shell dpkg-architecture -qDEB_HOST_MULTIARCH)/perl5/$(shell perl -MConfig -e '\''print $$Config{version};'\'')#' \
                    "${dir}/Makefile"
            fi
            ;;
        libpve-access-control)
            if [[ -f "${dir}/src/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/Makefile" \
                    pveum.1 \
                    pveum.bash-completion \
                    pveum.zsh-completion
            fi
            ;;
        libpve-storage-perl)
            relax_rbd_plugin_rados_dependency "${dir}/src/PVE/Storage/RBDPlugin.pm"
            if [[ -f "${dir}/src/bin/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/bin/Makefile" \
                    pvesm.1 \
                    pvesm.bash-completion \
                    pvesm.zsh-completion
            fi
            ;;
        kronosnet)
            export DOXYGEN2MAN=/usr/bin/doxygen2man
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i \
                    -e 's/libknet1_/libknet1t64_/g' \
                    -e 's/libknet1-dbgsym_/libknet1t64-dbgsym_/g' \
                    -e 's/libnozzle1_/libnozzle1t64_/g' \
                    -e 's/libnozzle1-dbgsym_/libnozzle1t64-dbgsym_/g' \
                    "${dir}/Makefile"
            fi
            ;;
        lxcfs)
            if [[ -f "${dir}/debian/control" ]]; then
                perl -0pi -e 's/\bhelp2man\b/help2man:native/g; s/\bpython3-jinja2\b/python3-jinja2:native/g' "${dir}/debian/control"
            fi
            ;;
        lvm2)
            rm -f "${dir}/debian/libdevmapper-event1.02.1.symbols"
            if [[ -f "${dir}/debian/dmsetup.install" ]]; then
                perl -0pi -e 's#^usr/lib/udev/rules\.d/\*-dm\*\.rules$#usr/lib/udev/rules.d/10-dm.rules\nusr/lib/udev/rules.d/95-dm-notify.rules#m' "${dir}/debian/dmsetup.install"
            fi
            if [[ -f "${dir}/debian/control" ]] && ! awk '
                /^Package: lvm2$/ { in_lvm2 = 1; next }
                /^Package:/ { in_lvm2 = 0 }
                in_lvm2 && /^Replaces:/ { found = 1 }
                END { exit found ? 0 : 1 }
            ' "${dir}/debian/control"; then
                perl -0pi -e 's/(Package: lvm2.*?^Multi-Arch: foreign\n)/$1Replaces:\n dmsetup (<= \${devmapper:Version})\n/sm' "${dir}/debian/control"
            fi
            ;;
        proxmox-archive-keyring)
            if [[ -f "${dir}/debian/rules" ]] && grep -q 'sq keyring join --binary' "${dir}/debian/rules"; then
                sed -i \
                    's#sq keyring join --binary debian/proxmox-release\*.gpg >proxmox-archive-keyring.gpg.tmp#sq keyring merge debian/proxmox-release*.gpg | sq packet dearmor >proxmox-archive-keyring.gpg.tmp#' \
                    "${dir}/debian/rules"
            fi
            ;;
        proxmox-mini-journalreader)
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i 's/$(DEB_BUILD_ARCH)/$(DEB_HOST_ARCH)/g' "${dir}/Makefile"
            fi
            if [[ -f "${dir}/src/Makefile" ]]; then
                sed -i 's/pkg-config --/$(PKG_CONFIG) --/g; s/^	gcc /	$(CC) /' "${dir}/src/Makefile"
            fi
            ;;
        pve-firewall)
            if [[ -f "${dir}/src/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/Makefile" \
                    pve-firewall.8 \
                    pve-firewall.bash-completion \
                    pve-firewall.zsh-completion
                sed -i \
                    -e 's/$(shell pkg-config /$(shell $(PKG_CONFIG) /g' \
                    -e 's/^	gcc /	$(CC) /' \
                    "${dir}/src/Makefile"
            fi
            ;;
        pve-container)
            if [[ -f "${dir}/src/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/Makefile" \
                    pct.1 \
                    pct.conf.5 \
                    pct.bash-completion \
                    pct.zsh-completion
                perl -0pi -e 's/^\t.*verify_api\(\);.*$/\t:/mg' "${dir}/src/Makefile"
                perl -0pi -e 's#pve-userns\.seccomp: /usr/share/lxc/config/common\.seccomp\n\tcp \$< \$@\n\techo '"'"'keyctl errno 38'"'"' >> \$@#pve-userns.seccomp:\n\t: > \$@\n\techo '"'"'keyctl errno 38'"'"' >> \$@#' "${dir}/src/Makefile"
            fi
            ;;
        pve-ha-manager)
            if [[ -f "${dir}/src/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/Makefile" \
                    ha-manager.1 \
                    pve-ha-crm.8 \
                    pve-ha-lrm.8 \
                    ha-manager.bash-completion \
                    pve-ha-lrm.bash-completion \
                    pve-ha-crm.bash-completion \
                    ha-manager.zsh-completion \
                    pve-ha-lrm.zsh-completion \
                    pve-ha-crm.zsh-completion
                sed -i \
                    -e 's/^	gcc /	$(CC) /' \
                    "${dir}/src/Makefile"
                perl -0pi -e 's/^\t.*verify_api\(\);.*$/\t:/mg' "${dir}/src/Makefile"
            fi
            ;;
        pve-manager)
            relax_pve_manager_rados_dependency "${dir}"
            if [[ -f "${dir}/bin/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/bin/Makefile" \
                    pvestatd.8 pveproxy.8 pvedaemon.8 spiceproxy.8 pvescheduler.8 \
                    vzdump.1 pvesubscription.1 pveceph.1 pveam.1 pvesr.1 pvenode.1 pvesh.1 pve8to9.1 \
                    pve-network-interface-pinning.1 pveversion.1 pveupgrade.1 pveperf.1 pvereport.1 \
                    pvestatd.service-bash-completion pveproxy.service-bash-completion pvedaemon.service-bash-completion spiceproxy.service-bash-completion pvescheduler.service-bash-completion \
                    vzdump.bash-completion pvesubscription.bash-completion pveceph.bash-completion pveam.bash-completion pvesr.bash-completion pvenode.bash-completion pvesh.bash-completion pve8to9.bash-completion \
                    pve-network-interface-pinning.bash-completion \
                    pvestatd.service-zsh-completion pveproxy.service-zsh-completion pvedaemon.service-zsh-completion spiceproxy.service-zsh-completion pvescheduler.service-zsh-completion \
                    vzdump.zsh-completion pvesubscription.zsh-completion pveceph.zsh-completion pveam.zsh-completion pvesr.zsh-completion pvenode.zsh-completion pvesh.zsh-completion pve8to9.zsh-completion \
                    pve-network-interface-pinning.zsh-completion
            fi
            if [[ -f "${dir}/www/manager6/Makefile" ]]; then
                perl -0pi -e '
                    s/^OnlineHelpInfo\.js:.*?\n\t\/usr\/bin\/asciidoc-pve scan-extjs .*?\n\tmv \$@\.tmp \$@\n/OnlineHelpInfo.js:\n\tprintf "const pveOnlineHelpInfo = {};\\n" > \$@\n/sm;
                ' "${dir}/www/manager6/Makefile"
            fi
            ;;
        qemu-server)
            if [[ -f "${dir}/src/bin/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/bin/Makefile" \
                    qm.1 qmrestore.1 qm.conf.5 cpu-models.conf.5 \
                    qm.bash-completion qmrestore.bash-completion \
                    qm.zsh-completion qmrestore.zsh-completion
            fi
            if [[ -f "${dir}/src/qmeventd/Makefile" ]]; then
                replace_make_targets_with_placeholders \
                    "${dir}/src/qmeventd/Makefile" \
                    qmeventd.8
                sed -i 's/pkgconf --/$(PKG_CONFIG) --/g' "${dir}/src/qmeventd/Makefile"
            fi
            ;;
        pve-docs)
            if [[ -f "${dir}/Makefile" ]]; then
                perl -0pi -e '
                    s/^all:.*$/all:\n\t: > index.html/m;
                    s/^gen-install:.*?(?=^\.PHONY: doc-install)/gen-install:\n\tinstall -dm755 \$(DESTDIR)\/usr\/share\/\$(GEN_PACKAGE)\n\tinstall -dm755 \$(DESTDIR)\/usr\/share\/doc\/\$(GEN_PACKAGE)\n\tinstall -dm755 \$(DESTDIR)\/usr\/bin\n\tmkdir -p generated\n\tprintf "# cross-build placeholder\\n" > pve-doc-generator.mk\n\tprintf "<docinfo><\/docinfo>\\n" > docinfo.xml\n\tprintf "#!\/bin\/sh\\nexit 0\\n" > asciidoc-pve\n\tchmod 0755 asciidoc-pve\n\tinstall -m 0644 pve-doc-generator.mk docinfo.xml \$(DESTDIR)\/usr\/share\/\$(GEN_PACKAGE)\n\tinstall -m 0755 asciidoc-pve \$(DESTDIR)\/usr\/bin\/\n\tinstall -m 0755 \$(GEN_SCRIPTS) \$(DESTDIR)\/usr\/share\/\$(GEN_PACKAGE)\n\tinstall -D -m 0644 asciidoc\/mediawiki.conf \$(DESTDIR)\/usr\/share\/\$(GEN_PACKAGE)\/asciidoc\/mediawiki.conf\n\tinstall -m 0644 asciidoc\/asciidoc-pve.conf asciidoc\/pve-docbook.conf asciidoc\/pve-html.conf \$(DESTDIR)\/usr\/share\/\$(GEN_PACKAGE)\/asciidoc\/\n\n/sm;
                    s/^doc-install:.*?(?=^\.PHONY: mediawiki-install)/doc-install:\n\tinstall -dm755 \$(DESTDIR)\/usr\/share\/\$(DOC_PACKAGE)\n\tinstall -dm755 \$(DESTDIR)\/usr\/share\/doc\/\$(DOC_PACKAGE)\n\tprintf "<!doctype html><title>Proxmox VE Documentation<\/title>\\n" > index.html\n\tinstall -m 0644 index.html \$(DESTDIR)\/usr\/share\/\$(DOC_PACKAGE)\n\n/sm;
                    s/^mediawiki-install:.*?(?=^\.PHONY: upload)/mediawiki-install:\n\tinstall -dm755 \$(DESTDIR)\/usr\/share\/\$(MEDIAWIKI_PACKAGE)\n\tinstall -dm755 \$(DESTDIR)\/usr\/share\/doc\/\$(MEDIAWIKI_PACKAGE)\n\tinstall -dm755 \$(DESTDIR)\/usr\/bin\n\tprintf "#!\/bin\/sh\\nexit 0\\n" > pve-docs-mediawiki-import\n\tchmod 0755 pve-docs-mediawiki-import\n\tinstall -m 0755 pve-docs-mediawiki-import \$(DESTDIR)\/usr\/bin\/\n\n/sm;
                ' "${dir}/Makefile"
            fi
            ;;
        pve-qemu-kvm)
            run_root apt-get install -y --no-install-recommends "libproxmox-backup-qemu0-dev:${HOST_ARCH}"
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i 's#dpkg-buildpackage -d -b -us -uc#dpkg-buildpackage -d -b -a$(DEB_HOST_ARCH) -us -uc#' "${dir}/Makefile"
            fi
            if [[ -f "${dir}/debian/control" ]]; then
                perl -0pi -e '
                    s/^\s*librbd-dev[^\n]*,\n//mg;
                    s/^Depends: ceph-common[^\n]*,\n/Depends: /m;
                ' "${dir}/debian/control"
            fi
            if [[ -f "${dir}/debian/rules" ]]; then
                sed -i 's/--enable-rbd/--disable-rbd/' "${dir}/debian/rules"
                if ! grep -q -- '--cross-prefix="$(DEB_HOST_GNU_TYPE)-"' "${dir}/debian/rules"; then
                    sed -i '/--disable-download \\/a\
		    --cross-prefix="$(DEB_HOST_GNU_TYPE)-" \
		    --host-cc="gcc" \
		    --cpu="$(DEB_HOST_GNU_CPU)" \\\\' "${dir}/debian/rules"
	                fi
	                sed -i \
	                    -e 's/^\([[:space:]]*--cross-prefix="$(DEB_HOST_GNU_TYPE)-"\)[[:space:]\\]*$/\1 \\/' \
	                    -e 's/^\([[:space:]]*--host-cc="gcc"\)[[:space:]\\]*$/\1 \\/' \
	                    -e 's/^\([[:space:]]*--cpu="$(DEB_HOST_GNU_CPU)"\)[[:space:]\\]*$/\1 \\/' \
	                    "${dir}/debian/rules"
	            fi
            if [[ -d "${dir}/qemu" ]]; then
                (cd "${dir}/qemu" && meson subprojects download)
                if [[ -d "${dir}/qemu/python/wheels" ]]; then
                    cp -n /usr/share/python-wheels/*.whl "${dir}/qemu/python/wheels/" 2>/dev/null || true
                fi
            fi
            ;;
        proxmox-firewall)
            if [[ -f "${dir}/debian/control" ]]; then
                native_qualify_rust_build_deps "${dir}/debian/control"
            fi
            if [[ -f "${dir}/debian/proxmox-firewall.install" ]]; then
                sed -i 's#target/x86_64-unknown-linux-gnu/release/#target/aarch64-unknown-linux-gnu/release/#g' "${dir}/debian/proxmox-firewall.install"
            fi
            ;;
        pve-cluster)
            if [[ -f "${dir}/src/PVE/Makefile" ]] && ! grep -q 'cross-build placeholder docs' "${dir}/src/PVE/Makefile"; then
                local tmp_makefile
                tmp_makefile=$(mktemp)
                awk '
                    /^-include \/usr\/share\/pve-doc-generator\/pve-doc-generator.mk/ && !inserted {
                        print ""
                        print "# cross-build placeholder docs avoid loading target-arch PVE::IPCC."
                        print ".PHONY: cleanup-docgen"
                        print "cleanup-docgen:"
                        print "\trm -f *.xml.tmp *.1 *.5 *.8 *.adoc docinfo.xml"
                        print "\trm -rf generated"
                        print ""
                        print "pvecm.1:"
                        print "\tprintf \".TH pvecm 1\\n.SH NAME\\npvecm - Proxmox VE cluster manager\\n\" > $@"
                        print ""
                        print "datacenter.cfg.5:"
                        print "\tprintf \".TH datacenter.cfg 5\\n.SH NAME\\ndatacenter.cfg - Proxmox VE datacenter configuration\\n\" > $@"
                        print ""
                        print "pvecm.bash-completion:"
                        print "\t: > $@"
                        print ""
                        print "pvecm.zsh-completion:"
                        print "\t: > $@"
                        print ""
                        inserted = 1
                        next
                    }
                    { print }
                ' "${dir}/src/PVE/Makefile" > "${tmp_makefile}"
                mv "${tmp_makefile}" "${dir}/src/PVE/Makefile"
            fi
            if [[ -f "${dir}/src/PVE/Makefile" ]]; then
                sed -i \
                    -e 's#^PERL_VENDORARCH=.*#PERL_VENDORARCH=/usr/lib/$(DEB_HOST_MULTIARCH)/perl5/$(shell perl -MConfig -e '\''print $$Config{version};'\'')#' \
                    -e 's/^CC=gcc$/CC ?= gcc/' \
                    -e 's/pkg-config --/$(PKG_CONFIG) --/g' \
                    "${dir}/src/PVE/Makefile"
            fi
            ;;
        rrdtool)
            if [[ -f "${dir}/debian/control" ]]; then
                perl -0pi -e '
                    s/\bdc\b/dc:native/g;
                    s/\bdh-python\b/dh-python:native/g;
                    s/^\s*gem2deb(?::native)?,\n//mg;
                    s/\bperl\s*\(/perl:native (/g;
                    s/^\s*dh-lua(?::native)?,\n//mg;
                    s/^\s*python3-all-dev,\n//mg;
                    s/^\s*python3-setuptools(?::native)?,\n//mg;
                    s/\nPackage: python3-rrdtool\n.*?(?=\nPackage: )/\n/s;
                    s/\nPackage: ruby-rrd\n.*?(?=\nPackage: )/\n/s;
                    s/\nPackage: lua-rrd\n.*?(?=\nPackage: )/\n/s;
                    s/\nPackage: lua-rrd-dev\n.*?(?=\nPackage: |\z)//s;
                ' "${dir}/debian/control"
                rm -f "${dir}/debian/python3-rrdtool.install"
                rm -f "${dir}"/debian/ruby-rrd*
                rm -f "${dir}"/debian/lua-rrd*
                grep -qxF 'usr/share/rrdtool/examples/stripes.py' "${dir}/debian/not-installed" 2>/dev/null \
                    || printf '%s\n' 'usr/share/rrdtool/examples/stripes.py' >> "${dir}/debian/not-installed"
            fi
            if [[ -f "${dir}/debian/rules" ]]; then
                perl -0pi -e '
                    s/--with lua,python3,ruby/--with ruby/g;
                    s/--with lua,ruby/--with ruby/g;
                    s/--with ruby//g;
                    s/dh \$@ --with\s*$/dh \$@/mg;
                    s/^\s*dh_auto_(?:configure|clean|build|install) --buildsystem=lua\n//mg;
                    s/^\s*dh_auto_(?:configure|clean|build|install) --buildsystem=ruby\n//mg;
                    s/^\s*dh_auto_(?:configure|clean|build|install) --buildsystem=pybuild --sourcedirectory=bindings\/python\n//mg;
                    s/^override_dh_strip:\n\tdh_strip --package=python3-rrdtool --dbgsym-migration=.*\n\tdh_strip --no-package=python3-rrdtool /override_dh_strip:\n\tdh_strip /m;
                ' "${dir}/debian/rules"
            fi
            ;;
        smartmontools)
            if [[ -f "${dir}/Makefile" ]]; then
                sed -i 's/DEB_BUILD_ARCH/DEB_HOST_ARCH/g' "${dir}/Makefile"
            fi
            if [[ -f "${dir}/smartmontools/autogen.sh" ]]; then
                sed -i \
                    -e 's/for v in 1\.16 /for v in 1.17 1.16 /' \
                    -e 's/1\.16|1\.16\.\[12\])/1.16|1.16.[12]|1.17|1.17.[0-9])/' \
                    "${dir}/smartmontools/autogen.sh"
            fi
            ;;
        spiceterm)
            if [[ -f "${dir}/src/Makefile" ]]; then
                sed -i 's/pkg-config --/$(PKG_CONFIG) --/g; s/^	gcc -Werror/	$(CC) -Werror/' "${dir}/src/Makefile"
            fi
            ;;
        rust-proxmox-backup)
            if [[ -f "${dir}/debian/control" ]]; then
                native_qualify_rust_build_deps "${dir}/debian/control"
                perl -0pi -e 's/^\s*librust-cidr-0\.3\+default-dev(?::native)?[^\n]*,\n//mg' "${dir}/debian/control"
                perl -0pi -e 's/^\s*librust-proxmox-rest-server-1\+(?:rate-limited-stream|templates)-dev(?::native)?[^\n]*,\n//mg' "${dir}/debian/control"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'cidr-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/cidr-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'crossbeam-channel-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/crossbeam-channel-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'pathpatterns-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/pathpatterns-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'pam-sys-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/pam-sys-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'udev-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/udev-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-rest-server-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-rest-server-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-docgen-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-docgen-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-ldap-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-ldap-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-metrics-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-metrics-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-openid-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-openid-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-parallel-handler-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-parallel-handler-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-upgrade-checks-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-upgrade-checks-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/debian/rules" ]] && ! grep -q 'proxmox-rrd-.*debian/cargo_registry' "${dir}/debian/rules"; then
                sed -i '/prepare-debian/a\
	for crate in /usr/share/cargo/registry/proxmox-rrd-*; do [ -e "$$crate" ] && ln -sfn "$$crate" debian/cargo_registry/$${crate##*/}; done' "${dir}/debian/rules"
            fi
            if [[ -f "${dir}/docs/Makefile" ]]; then
                sed -i 's/install: install_manual_pages install_html install_pdf/install: install_manual_pages install_html/' "${dir}/docs/Makefile"
            fi
            if [[ -f "${dir}/debian/proxmox-backup-docs.install" ]]; then
                sed -i '\#/usr/share/doc/proxmox-backup/proxmox-backup.pdf#d' "${dir}/debian/proxmox-backup-docs.install"
            fi
            ;;
        rust-proxmox-offline-mirror)
            if [[ -f "${dir}/debian/control" ]]; then
                native_qualify_rust_build_deps "${dir}/debian/control"
            fi
            if [[ -f "${dir}/docs/Makefile" ]]; then
                sed -i 's/install: install_manual_pages install_html install_pdf install_examples/install: install_manual_pages install_html install_examples/' "${dir}/docs/Makefile"
            fi
            ;;
        proxmox-backup-qemu|proxmox-termproxy|pve-esxi-import-tools|pve-lxc-syscalld|pve-yew-mobile-gui|rust-proxmox-mail-forward|rust-proxmox-websocket-tunnel)
            if [[ -f "${dir}/debian/control" ]]; then
                native_qualify_rust_build_deps "${dir}/debian/control"
            fi
            ;;
        swtpm)
            export PKG_CONFIG_PATH="/usr/lib/${HOST_ARCH/arm64/aarch64-linux-gnu}/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
            ;;
    esac
}

build_with_env() {
    local dir=$1
    shift

    (
        cd "${dir}"
        export DEB_BUILD_OPTIONS="nocheck parallel=${JOBS}"
        export DEB_BUILD_PROFILES="${DEB_BUILD_PROFILES:-nocheck cross}"
        export DEB_BUILD_ARCH="${BUILD_ARCH}"
        export DEB_HOST_ARCH="${HOST_ARCH}"
        export DEB_HOST_GNU_TYPE="aarch64-linux-gnu"
        export DEB_HOST_MULTIARCH="aarch64-linux-gnu"
        export DEB_CFLAGS_MAINT_STRIP="-mbranch-protection=standard ${DEB_CFLAGS_MAINT_STRIP:-}"
        export DEB_CXXFLAGS_MAINT_STRIP="-mbranch-protection=standard ${DEB_CXXFLAGS_MAINT_STRIP:-}"
        export CC="aarch64-linux-gnu-gcc"
        export CXX="aarch64-linux-gnu-g++"
        export PKG_CONFIG="aarch64-linux-gnu-pkg-config"
        export PKG_CONFIG_ALLOW_CROSS=1
        export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
        export HOST_CC="gcc"
        export HOST_CXX="g++"
        export HOST_PKG_CONFIG="pkg-config"
        native_cflags="-g -O2 -ffile-prefix-map=${PWD}=. -fstack-protector-strong -fstack-clash-protection -Wformat -Werror=format-security"
        export HOST_CFLAGS="${native_cflags}"
        export HOST_CXXFLAGS="${native_cflags}"
        export CFLAGS_x86_64_unknown_linux_gnu="${native_cflags}"
        export CXXFLAGS_x86_64_unknown_linux_gnu="${native_cflags}"
        export CC_x86_64_unknown_linux_gnu="gcc"
        export CXX_x86_64_unknown_linux_gnu="g++"
        export AR_x86_64_unknown_linux_gnu="ar"
        export PKG_CONFIG_x86_64_unknown_linux_gnu="pkg-config"
        export PKG_CONFIG_PATH_x86_64_unknown_linux_gnu="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
        export PKG_CONFIG_LIBDIR_x86_64_unknown_linux_gnu="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
        export CC_aarch64_unknown_linux_gnu="aarch64-linux-gnu-gcc"
        export CXX_aarch64_unknown_linux_gnu="aarch64-linux-gnu-g++"
        export AR_aarch64_unknown_linux_gnu="aarch64-linux-gnu-ar"
        export PKG_CONFIG_aarch64_unknown_linux_gnu="aarch64-linux-gnu-pkg-config"
        export PKG_CONFIG_PATH_aarch64_unknown_linux_gnu="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
        export PKG_CONFIG_LIBDIR_aarch64_unknown_linux_gnu="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
        export OPENSSL_NO_VENDOR=1
        export CARGO_HOME="${HOME}/.cargo"
        export RUSTUP_HOME="${HOME}/.rustup"
        export RUSTUP_TOOLCHAIN=stable
        export PATH="${CARGO_HOME}/bin:${PATH}"
        export CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_AR=aarch64-linux-gnu-ar
        "$@"
    )
}

build_native_with_env() {
    local dir=$1
    shift

    (
        cd "${dir}"
        export DEB_BUILD_OPTIONS="nocheck parallel=${JOBS}"
        export DEB_BUILD_PROFILES="${DEB_BUILD_PROFILES:-nocheck}"
        export CARGO_HOME="${HOME}/.cargo"
        export RUSTUP_HOME="${HOME}/.rustup"
        export RUSTUP_TOOLCHAIN=stable
        export PATH="${CARGO_HOME}/bin:${PATH}"
        "$@"
    )
}

build_source() {
    local source=$1
    local dir=$2
    local stamp="${LOG_DIR}/${source}.stamp"
    local control

    if [[ ! -f "${dir}/debian/control" && ! -f "${dir}/Makefile" && ! -f "${dir}/GNUmakefile" ]]; then
        log "${source}: no debian/control in ${dir}"
        return 1
    fi

    reset_git_tree_for_dir "${dir}"

    apply_source_fixes "${source}" "${dir}"
    touch "${stamp}"

    if has_proxmox_wrapper "${dir}"; then
        control=$(control_file_for_dir "${dir}")
        if ! install_wrapper_build_deps "${dir}"; then
            log "${source}: continuing after build-deps install failure"
        fi
        cleanup_build_dep_artifacts "${dir}"
        if [[ -z "${control}" || ! -f "${control}" ]] || control_has_arch_any_for_host "${control}"; then
            if ! build_with_env "${dir}" make deb; then
                return 1
            fi
        else
            if ! build_native_with_env "${dir}" make deb; then
                return 1
            fi
        fi
        move_new_artifacts "${dir}" "${stamp}"
        refresh_local_repo
        if ! find "${OUT_DIR}" -maxdepth 1 -type f -newer "${stamp}" -name '*.deb' | grep -q .; then
            log "${source}: no deb artifacts produced for ${HOST_ARCH}/all"
            return 1
        fi
        return 0
    fi

    if control_has_arch_any_for_host "${dir}/debian/control"; then
        if ! install_build_deps_any "${dir}"; then
            log "${source}: continuing after arch-any build-deps install failure"
        fi
        cleanup_build_dep_artifacts "${dir}"
        if ! build_with_env "${dir}" dpkg-buildpackage -d -us -uc -B -a"${HOST_ARCH}"; then
            return 1
        fi
        move_new_artifacts "${dir}" "${stamp}"
        refresh_local_repo
    fi

    if control_has_arch_all "${dir}/debian/control"; then
        if skip_arch_all_after_arch_any "${source}" && find "${OUT_DIR}" -maxdepth 1 -type f -newer "${stamp}" -name '*.deb' | grep -q .; then
            log "${source}: skipping arch-all package set after successful arch-any build"
            return 0
        fi
        if ! install_build_deps_all "${dir}"; then
            log "${source}: continuing after arch-all build-deps install failure"
        fi
        cleanup_build_dep_artifacts "${dir}"
        if ! build_native_with_env "${dir}" dpkg-buildpackage -d -us -uc -A; then
            return 1
        fi
        move_new_artifacts "${dir}" "${stamp}"
        refresh_local_repo
    fi

    if ! find "${OUT_DIR}" -maxdepth 1 -type f -newer "${stamp}" -name '*.deb' | grep -q .; then
        log "${source}: no deb artifacts produced for ${HOST_ARCH}/all"
        return 1
    fi
}

prepare_apt

if [[ ! -s "${SRC_DIR}/proxmox-project-index.txt" ]]; then
    curl -fsSL 'https://git.proxmox.com/?a=project_index' \
        | awk '{ print $1 }' \
        | grep '\.git$' \
        | sort > "${SRC_DIR}/proxmox-project-index.txt"
fi

if [[ ! -d "${SRC_DIR}/package-rebuilds/.git" ]]; then
    git clone --depth=1 "$(repo_url package-rebuilds)" "${SRC_DIR}/package-rebuilds"
else
    git -C "${SRC_DIR}/package-rebuilds" pull --ff-only || true
fi

computed_sources="${LOG_DIR}/sources.computed"
ordered_sources_file="${LOG_DIR}/sources.ordered"
load_sources | tee "${computed_sources}" >/dev/null
ordered_sources "${computed_sources}" | tee "${ordered_sources_file}" >/dev/null

log "source package count: $(wc -l < "${ordered_sources_file}")"
cp "${ordered_sources_file}" "${LOG_DIR}/pending.initial"
if [[ "${RESUME_BUILT:-1}" == 1 && -s "${LOG_DIR}/built.txt" ]]; then
    log "resuming with $(wc -l < "${LOG_DIR}/built.txt") previously built sources"
else
    : > "${LOG_DIR}/built.txt"
fi
: > "${LOG_DIR}/failed.txt"

pending="${ordered_sources_file}"
for pass in $(seq 1 "${MAX_PASSES}"); do
    log "starting build pass ${pass}"
    next_pending="${LOG_DIR}/pending.pass${pass}.next"
    : > "${next_pending}"

    while read -r source; do
        [[ -n "${source}" ]] || continue
        if grep -qx "${source}" "${LOG_DIR}/built.txt"; then
            continue
        fi

        log "building ${source}"
        build_log="${LOG_DIR}/${source}.pass${pass}.log"

        if dir=$(source_dir_for "${source}" 2>&1); then
            dir=$(printf '%s\n' "${dir}" | tail -1)
            if build_source "${source}" "${dir}" >"${build_log}" 2>&1; then
                log "built ${source}"
                printf '%s\n' "${source}" >> "${LOG_DIR}/built.txt"
            else
                log "failed ${source}; see ${build_log}"
                printf '%s\n' "${source}" >> "${next_pending}"
            fi
        else
            log "failed to prepare ${source}; see ${build_log}"
            printf '%s\n' "${source}" >> "${next_pending}"
        fi
    done < "${pending}"

	if [[ ! -s "${next_pending}" ]]; then
	    log "all sources built"
	    pending="${next_pending}"
	    break
	fi

    pending="${next_pending}"
done

cp "${pending}" "${LOG_DIR}/failed.txt"
log "build complete: $(wc -l < "${LOG_DIR}/built.txt") built, $(wc -l < "${LOG_DIR}/failed.txt") failed/pending"
log "artifacts: ${OUT_DIR}"
