#!/usr/bin/env bash
# kernel.sh — Kernel installation for Void Linux
source "${LIB_DIR}/protection.sh"

# kernel_install — Install kernel, headers, firmware and microcode
kernel_install() {
    local kernel_type="${KERNEL_TYPE:-mainline}"

    einfo "Installing kernel (${kernel_type})..."

    local kernel_pkg="linux"
    local headers_pkg="linux-headers"

    if [[ "${kernel_type}" == "lts" ]]; then
        kernel_pkg="linux-lts"
        headers_pkg="linux-lts-headers"
    fi

    # Install kernel + headers
    try "Installing ${kernel_pkg}" xbps-install -y "${kernel_pkg}" "${headers_pkg}"

    # Install firmware
    try "Installing firmware" xbps-install -y linux-firmware linux-firmware-amd linux-firmware-intel linux-firmware-nvidia

    # Intel microcode (if Intel CPU — requires nonfree repo)
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        einfo "Intel CPU detected — installing microcode"
        # Ensure nonfree repo is available (intel-ucode is nonfree)
        if ! xbps-query void-repo-nonfree &>/dev/null; then
            try "Enabling nonfree repository" xbps-install -Sy void-repo-nonfree
        fi
        try "Installing Intel microcode" xbps-install -Sy intel-ucode
    fi

    # AMD microcode (if AMD CPU)
    if grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        einfo "AMD CPU detected — microcode included in linux-firmware"
    fi

    einfo "Kernel installation complete"
}
