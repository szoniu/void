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

# install_fingerprint_tools — Install fingerprint reader support
install_fingerprint_tools() {
    if [[ "${ENABLE_FINGERPRINT:-no}" != "yes" ]]; then
        return 0
    fi
    einfo "Installing fingerprint reader support..."
    try "Installing fprintd" xbps-install -y fprintd libfprint
    einfo "Fingerprint support installed"
}

# install_thunderbolt_tools — Install Thunderbolt device manager
install_thunderbolt_tools() {
    if [[ "${ENABLE_THUNDERBOLT:-no}" != "yes" ]]; then
        return 0
    fi
    einfo "Installing Thunderbolt support..."
    try "Installing bolt" xbps-install -y bolt
    _enable_service "boltd"
    einfo "Thunderbolt support installed"
}

# install_sensor_tools — Install IIO sensor proxy
install_sensor_tools() {
    if [[ "${ENABLE_SENSORS:-no}" != "yes" ]]; then
        return 0
    fi
    einfo "Installing IIO sensor support..."
    try "Installing iio-sensor-proxy" xbps-install -y iio-sensor-proxy
    einfo "IIO sensor support installed"
}

# install_wwan_tools — Install WWAN/LTE modem support
install_wwan_tools() {
    if [[ "${ENABLE_WWAN:-no}" != "yes" ]]; then
        return 0
    fi
    einfo "Installing WWAN/LTE support..."
    try "Installing ModemManager" xbps-install -y ModemManager libmbim libqmi
    _enable_service "ModemManager"
    einfo "WWAN/LTE support installed"
}

# install_asusctl_tools — Install ASUS ROG tools
install_asusctl_tools() {
    if [[ "${ENABLE_ASUSCTL:-no}" != "yes" ]]; then
        return 0
    fi
    einfo "Installing ASUS ROG tools..."
    try "Installing asusctl" xbps-install -y asusctl
    _enable_service "asusd"
    einfo "ASUS ROG tools installed"
}
