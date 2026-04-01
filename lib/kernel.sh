#!/usr/bin/env bash
# kernel.sh — Kernel installation for Void Linux (standard + Surface-patched)
source "${LIB_DIR}/protection.sh"

# kernel_install — Route to appropriate kernel installer based on KERNEL_TYPE
kernel_install() {
    local kernel_type="${KERNEL_TYPE:-mainline}"

    einfo "Installing kernel (${kernel_type})..."

    case "${kernel_type}" in
        mainline|lts)
            _kernel_install_standard "${kernel_type}"
            ;;
        surface-patched)
            _kernel_install_surface_patched
            ;;
        *)
            die "Unknown kernel type: ${kernel_type}"
            ;;
    esac

    einfo "Kernel installation complete"
}

# _kernel_install_standard — Install pre-built Void kernel (mainline or lts)
_kernel_install_standard() {
    local kernel_type="$1"

    local kernel_pkg="linux"
    local headers_pkg="linux-headers"

    if [[ "${kernel_type}" == "lts" ]]; then
        kernel_pkg="linux-lts"
        headers_pkg="linux-lts-headers"
    fi

    # Install kernel + headers
    try "Installing ${kernel_pkg}" xbps-install -y "${kernel_pkg}" "${headers_pkg}"

    # Install firmware
    _install_firmware

    einfo "Standard kernel (${kernel_type}) installed"
}

# _kernel_install_surface_patched — Build kernel from source with linux-surface patches
_kernel_install_surface_patched() {
    einfo "Building Surface-patched kernel from source..."
    einfo "This will take 30-60 minutes depending on your hardware."

    # Install standard kernel first as fallback
    try "Installing fallback kernel" xbps-install -y linux linux-headers

    # Install build dependencies
    try "Installing kernel build dependencies" \
        xbps-install -y git bc flex bison perl elfutils-devel openssl-devel \
        make gcc ncurses-devel dracut

    # Install firmware
    _install_firmware

    # Detect installed kernel version
    local kernel_version
    kernel_version=$(xbps-query -p pkgver linux 2>/dev/null | sed 's/^linux-//' | cut -d_ -f1) || true
    if [[ -z "${kernel_version}" ]]; then
        ewarn "Could not detect kernel version from XBPS — falling back to uname"
        kernel_version=$(uname -r | sed 's/-.*//')
    fi

    local major minor
    major=$(echo "${kernel_version}" | cut -d. -f1)
    minor=$(echo "${kernel_version}" | cut -d. -f2)

    einfo "Kernel version: ${kernel_version} (${major}.${minor})"

    # Download kernel source
    local src_dir="/usr/src/linux-${kernel_version}"
    local src_tarball="/tmp/linux-${kernel_version}.tar.xz"
    local src_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${kernel_version}.tar.xz"

    if [[ ! -d "${src_dir}" ]]; then
        try "Downloading kernel source" \
            curl -fsSL -o "${src_tarball}" "${src_url}"
        try "Extracting kernel source" \
            tar xf "${src_tarball}" -C /usr/src/
        rm -f "${src_tarball}"
    fi

    # Clone linux-surface patches
    local surface_dir="/tmp/linux-surface"
    if [[ ! -d "${surface_dir}" ]]; then
        try "Cloning linux-surface patches" \
            git clone --depth 1 https://github.com/linux-surface/linux-surface.git "${surface_dir}"
    fi

    # Find patch directory for this kernel version
    local patch_dir="${surface_dir}/patches/${major}.${minor}"
    if [[ ! -d "${patch_dir}" ]]; then
        # Fallback: use highest available patch version
        patch_dir=$(ls -d "${surface_dir}"/patches/[0-9]* 2>/dev/null | sort -V | tail -1) || true
        local patches_version
        patches_version=$(basename "${patch_dir}" 2>/dev/null) || true
        ewarn "No patches for kernel ${major}.${minor} — using ${patches_version} (latest available)"
        ewarn "Some patches may not apply cleanly. This is expected."
    fi

    # Apply patches (dry-run first, skip failures gracefully)
    if [[ -n "${patch_dir}" && -d "${patch_dir}" ]]; then
        einfo "Applying patches from ${patch_dir}..."
        local p patch_name patch_ok=0 patch_skip=0
        for p in "${patch_dir}"/*.patch; do
            [[ -f "${p}" ]] || continue
            patch_name=$(basename "${p}")

            if patch -d "${src_dir}" -p1 -N --dry-run < "${p}" &>/dev/null; then
                patch -d "${src_dir}" -p1 -N < "${p}" >> "${LOG_FILE}" 2>&1
                einfo "Applied: ${patch_name}"
                (( patch_ok++ )) || true
            else
                ewarn "Skipped: ${patch_name} (does not apply cleanly)"
                (( patch_skip++ )) || true
            fi
        done
        einfo "Patches: ${patch_ok} applied, ${patch_skip} skipped"
    else
        ewarn "No linux-surface patches found — building unpatched kernel"
    fi

    # Copy Void kernel config as base
    local base_config=""
    base_config=$(ls /boot/config-* 2>/dev/null | sort -V | tail -1) || true
    if [[ -n "${base_config}" && -f "${base_config}" ]]; then
        cp "${base_config}" "${src_dir}/.config"
        # Update config for new options (accept defaults)
        make -C "${src_dir}" olddefconfig >> "${LOG_FILE}" 2>&1
    else
        ewarn "No base kernel config found — using defconfig"
        make -C "${src_dir}" defconfig >> "${LOG_FILE}" 2>&1
    fi

    # Set kernel extraversion to -surface
    sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-surface"/' "${src_dir}/.config"

    # Build kernel
    local nprocs
    nprocs=$(nproc 2>/dev/null || echo 4)
    try "Building kernel (${nprocs} threads)" \
        make -C "${src_dir}" -j"${nprocs}" bzImage modules

    # Install modules
    try "Installing kernel modules" \
        make -C "${src_dir}" modules_install

    # Install kernel
    try "Installing kernel image" \
        make -C "${src_dir}" install

    # Generate initramfs with dracut
    local kver
    kver=$(make -C "${src_dir}" -s kernelrelease 2>/dev/null) || true
    if [[ -n "${kver}" ]]; then
        try "Generating initramfs" \
            dracut --force "/boot/initramfs-${kver}.img" "${kver}"
    fi

    # Cleanup
    rm -rf "${surface_dir}" "${src_dir}"

    einfo "Surface-patched kernel installed"
}

# _install_firmware — Install firmware and microcode packages
_install_firmware() {
    try "Installing firmware" xbps-install -y linux-firmware linux-firmware-amd linux-firmware-intel linux-firmware-nvidia

    # Intel microcode (requires nonfree repo)
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        einfo "Intel CPU detected — installing microcode"
        if ! xbps-query void-repo-nonfree &>/dev/null; then
            try "Enabling nonfree repository" xbps-install -Sy void-repo-nonfree
        fi
        try "Installing Intel microcode" xbps-install -Sy intel-ucode
    fi

    # AMD microcode (included in linux-firmware)
    if grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        einfo "AMD CPU detected — microcode included in linux-firmware"
    fi
}
