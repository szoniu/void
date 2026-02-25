#!/usr/bin/env bash
# xbps.sh — XBPS package manager configuration and operations
source "${LIB_DIR}/protection.sh"

# xbps_configure_mirror — Set up XBPS mirror in target
xbps_configure_mirror() {
    local mirror="${MIRROR_URL:-${VOID_REPO_BASE}}"

    einfo "Configuring XBPS mirror: ${mirror}"

    mkdir -p "${MOUNTPOINT}/etc/xbps.d"

    # Override default repository
    echo "repository=${mirror}/current" > "${MOUNTPOINT}/etc/xbps.d/00-repository-main.conf"

    einfo "XBPS mirror configured"
}

# xbps_configure_nonfree — Enable nonfree repository
xbps_configure_nonfree() {
    if [[ "${ENABLE_NONFREE:-no}" != "yes" ]]; then
        return 0
    fi

    local mirror="${MIRROR_URL:-${VOID_REPO_BASE}}"

    einfo "Enabling nonfree repository"

    mkdir -p "${MOUNTPOINT}/etc/xbps.d"
    echo "repository=${mirror}/current/nonfree" > "${MOUNTPOINT}/etc/xbps.d/10-repository-nonfree.conf"

    einfo "Nonfree repository enabled"
}

# xbps_update — Update XBPS and install base-system (inside chroot)
xbps_update() {
    einfo "Updating XBPS package manager..."

    # First update xbps itself
    try "Updating xbps" xbps-install -Syu xbps

    # Full system update
    try "System update" xbps-install -Syu

    # Install base-system (replaces base-voidstrap from ROOTFS)
    try "Installing base-system" xbps-install -y base-system

    # Remove base-voidstrap (replaced by base-system)
    if xbps-query base-voidstrap &>/dev/null; then
        try "Removing base-voidstrap" xbps-remove -y base-voidstrap
    fi

    einfo "XBPS update complete"
}

# xbps_install_base — Install essential base packages
xbps_install_base() {
    local -a base_pkgs=(
        sudo
        bash-completion
        man-pages
        wget
        curl
    )

    einfo "Installing base packages..."
    try "Installing base packages" xbps-install -y "${base_pkgs[@]}"
    einfo "Base packages installed"
}

# install_extra_packages — Install user-selected extra packages
install_extra_packages() {
    local extras="${EXTRA_PACKAGES:-}"

    if [[ -z "${extras}" ]]; then
        einfo "No extra packages to install"
        return 0
    fi

    einfo "Installing extra packages: ${extras}"

    # Split space-separated list into array
    local -a pkg_list
    read -ra pkg_list <<< "${extras}"

    if [[ ${#pkg_list[@]} -gt 0 ]]; then
        try "Installing extra packages" xbps-install -y "${pkg_list[@]}"
    fi

    einfo "Extra packages installed"
}
