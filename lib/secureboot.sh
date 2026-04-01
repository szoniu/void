#!/usr/bin/env bash
# secureboot.sh — Secure Boot: MOK key generation, kernel signing, shim setup
source "${LIB_DIR}/protection.sh"

# Fedora shim RPM location (signed by Microsoft UEFI CA)
readonly _SHIM_FEDORA_VERSION="15.8"
readonly _SHIM_FEDORA_RELEASE="3"
readonly _SHIM_FEDORA_URL="https://kojipkgs.fedoraproject.org/packages/shim/${_SHIM_FEDORA_VERSION}/${_SHIM_FEDORA_RELEASE}/x86_64/shim-x64-${_SHIM_FEDORA_VERSION}-${_SHIM_FEDORA_RELEASE}.x86_64.rpm"

# MOK enrollment password used by MokManager at first boot
readonly _MOK_PASSWORD="void"

# is_secureboot_active — Check if Secure Boot is currently enabled in firmware
# Returns 0 if enabled, 1 if disabled or unknown
is_secureboot_active() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        return 1
    fi

    # Method 1: read EFI variable directly (works without mokutil)
    local sb_var
    sb_var=$(find /sys/firmware/efi/efivars/ -name 'SecureBoot-*' 2>/dev/null | head -1) || true
    if [[ -n "${sb_var}" ]]; then
        # EFI variable: 4 bytes attributes + 1 byte value (01=enabled, 00=disabled)
        local val
        val=$(od -An -tx1 -j4 -N1 "${sb_var}" 2>/dev/null | tr -d ' ') || true
        [[ "${val}" == "01" ]] && return 0
        return 1
    fi

    # Method 2: mokutil (may not be available)
    if command -v mokutil &>/dev/null; then
        mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled" && return 0
    fi

    return 1
}

# secureboot_setup — Full Secure Boot setup: keys, signing, shim, enrollment
secureboot_setup() {
    [[ "${ENABLE_SECUREBOOT:-no}" != "yes" ]] && return 0

    einfo "Setting up Secure Boot (MOK)..."

    local key_dir="/root/secureboot"
    mkdir -p "${key_dir}"
    chmod 700 "${key_dir}"

    # 1. Install required packages
    try "Installing sbsigntool" xbps-install -y sbsigntool
    try "Installing openssl" xbps-install -y openssl
    try "Installing bsdtar" xbps-install -y bsdtar

    # 2. Generate MOK key pair (if not already present)
    if [[ ! -f "${key_dir}/MOK.priv" || ! -f "${key_dir}/MOK.der" ]]; then
        einfo "Generating MOK key pair..."
        try "Generating MOK key pair" \
            openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
            -subj "/CN=Void Machine Owner Key/" \
            -keyout "${key_dir}/MOK.priv" -outform DER -out "${key_dir}/MOK.der"

        # Also create PEM version for sbsign
        try "Converting MOK to PEM" \
            openssl x509 -in "${key_dir}/MOK.der" -inform DER \
            -outform PEM -out "${key_dir}/MOK.pem"

        chmod 600 "${key_dir}/MOK.priv"
        einfo "MOK keys generated in ${key_dir}"
    else
        einfo "MOK keys already exist in ${key_dir}"
        # Ensure PEM exists
        if [[ ! -f "${key_dir}/MOK.pem" ]]; then
            openssl x509 -in "${key_dir}/MOK.der" -inform DER \
                -outform PEM -out "${key_dir}/MOK.pem" 2>/dev/null || true
        fi
    fi

    # 3. Sign existing kernels
    _sign_kernels "${key_dir}"

    # 4. Setup shim on ESP
    _setup_shim "${key_dir}"

    # 5. Queue MOK enrollment
    _enroll_mok "${key_dir}"

    # 6. Create kernel signing hook for future kernel updates
    _create_kernel_signing_hook "${key_dir}"

    einfo "Secure Boot setup complete"
    if is_secureboot_active; then
        einfo "At first reboot: MokManager will appear -> Enroll MOK -> password: ${_MOK_PASSWORD}"
    else
        einfo "Secure Boot is currently DISABLED in firmware"
        einfo "After installation: enable Secure Boot in BIOS/UEFI -> reboot"
        einfo "MokManager will appear -> Enroll MOK -> password: ${_MOK_PASSWORD}"
    fi
}

# _sign_kernels — Sign all existing kernel images
_sign_kernels() {
    local key_dir="$1"
    local priv="${key_dir}/MOK.priv"
    local cert="${key_dir}/MOK.pem"

    local kernel
    for kernel in /boot/vmlinuz-*; do
        [[ -f "${kernel}" ]] || continue

        # Check if already signed
        if sbverify --cert "${cert}" "${kernel}" &>/dev/null; then
            einfo "Already signed: ${kernel}"
            continue
        fi

        einfo "Signing: ${kernel}"
        try "Signing kernel $(basename "${kernel}")" \
            sbsign --key "${priv}" --cert "${cert}" --output "${kernel}" "${kernel}"
    done
}

# _setup_shim — Download Fedora shim and install on ESP
_setup_shim() {
    local key_dir="$1"
    local priv="${key_dir}/MOK.priv"
    local cert="${key_dir}/MOK.pem"
    local efi_dir="/boot/efi/EFI/Void"

    # Download shim RPM from Fedora (signed by Microsoft UEFI CA)
    local shim_tmp
    shim_tmp=$(mktemp -d /tmp/shim-download.XXXXXX)

    einfo "Downloading shim from Fedora..."
    try "Downloading shim RPM" \
        curl -fsSL -o "${shim_tmp}/shim.rpm" "${_SHIM_FEDORA_URL}"

    # Extract EFI binaries from RPM using bsdtar (libarchive, available in base Void)
    einfo "Extracting shim binaries..."
    try "Extracting shim RPM" \
        bsdtar -xf "${shim_tmp}/shim.rpm" -C "${shim_tmp}"

    # Find shimx64.efi and mmx64.efi in extracted contents
    local shim_src="" mm_src=""
    shim_src=$(find "${shim_tmp}" -name 'shimx64.efi' 2>/dev/null | head -1) || true
    mm_src=$(find "${shim_tmp}" -name 'mmx64.efi' 2>/dev/null | head -1) || true

    if [[ -z "${shim_src}" ]]; then
        ewarn "shimx64.efi not found in RPM — Secure Boot chainloading may not work"
        rm -rf "${shim_tmp}"
        return 0
    fi

    # Copy shim and MokManager to ESP
    mkdir -p "${efi_dir}"
    cp "${shim_src}" "${efi_dir}/shimx64.efi"
    [[ -f "${mm_src}" ]] && cp "${mm_src}" "${efi_dir}/mmx64.efi"

    # Copy MOK.der to ESP for manual enrollment fallback
    cp "${key_dir}/MOK.der" "${efi_dir}/MOK.der"

    # Sign GRUB with our MOK key
    local grub_efi="${efi_dir}/grubx64.efi"
    if [[ -f "${grub_efi}" ]]; then
        try "Signing GRUB" \
            sbsign --key "${priv}" --cert "${cert}" --output "${grub_efi}" "${grub_efi}"
    fi

    # Create EFI boot entry for shim (chainloads signed GRUB)
    if command -v efibootmgr &>/dev/null; then
        local esp_dev="${ESP_PARTITION:-}"
        if [[ -n "${esp_dev}" ]]; then
            local esp_disk="" esp_partnum=""
            if [[ "${esp_dev}" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
                esp_disk="${BASH_REMATCH[1]}"
                esp_partnum="${BASH_REMATCH[2]}"
            elif [[ "${esp_dev}" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
                esp_disk="${BASH_REMATCH[1]}"
                esp_partnum="${BASH_REMATCH[2]}"
            elif [[ "${esp_dev}" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
                esp_disk="${BASH_REMATCH[1]}"
                esp_partnum="${BASH_REMATCH[2]}"
            fi

            if [[ -n "${esp_disk}" && -n "${esp_partnum}" ]]; then
                # Remove existing "Void (Secure Boot)" entries
                local bootnum
                while bootnum=$(efibootmgr 2>/dev/null | grep -i "Void (Secure Boot)" | \
                    sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | head -1) && [[ -n "${bootnum}" ]]; do
                    efibootmgr --delete-bootnum --bootnum "${bootnum}" &>/dev/null || break
                done

                try "Creating Secure Boot EFI entry" \
                    efibootmgr --create --disk "${esp_disk}" --part "${esp_partnum}" \
                    --label "Void (Secure Boot)" \
                    --loader "\\EFI\\Void\\shimx64.efi"
            fi
        fi
    fi

    rm -rf "${shim_tmp}"
    einfo "Shim installed on ESP"
}

# _enroll_mok — Queue MOK key for enrollment at next reboot
_enroll_mok() {
    local key_dir="$1"
    local der="${key_dir}/MOK.der"

    # Try to install mokutil (may not be in Void repos)
    xbps-install -y mokutil &>/dev/null || true

    if ! command -v mokutil &>/dev/null; then
        ewarn "mokutil not available — MOK enrollment will happen via MokManager at first boot"
        ewarn "MokManager will find MOK.der on the ESP automatically"
        ewarn "If not, manually import: copy MOK.der and use 'Enroll key from disk' in MokManager"
        return 0
    fi

    # Generate password hash for MOK enrollment
    local pw_hash_file
    pw_hash_file=$(mktemp /tmp/mok-pw-hash.XXXXXX)
    trap 'rm -f "${pw_hash_file}"' RETURN

    mokutil --generate-hash="${_MOK_PASSWORD}" > "${pw_hash_file}" 2>/dev/null || true

    if [[ -s "${pw_hash_file}" ]]; then
        local import_rc=0
        try "Queuing MOK enrollment" \
            mokutil --import "${der}" --hash-file "${pw_hash_file}" || import_rc=$?
        if [[ ${import_rc} -eq 0 ]]; then
            einfo "MOK queued for enrollment (password: ${_MOK_PASSWORD})"
        fi
        if ! is_secureboot_active; then
            ewarn "Secure Boot is disabled — MOK enrollment may not persist"
            ewarn "After enabling Secure Boot, if MokManager does not appear, run:"
            ewarn "  mokutil --import '${der}' (password: ${_MOK_PASSWORD})"
        fi
    else
        ewarn "Could not generate MOK password hash — manual enrollment required"
        ewarn "Run: mokutil --import '${der}'"
    fi
}

# _create_kernel_signing_hook — Auto-sign kernels on future XBPS updates
_create_kernel_signing_hook() {
    local key_dir="$1"

    local hook_dir="/etc/kernel.d/post-install"
    mkdir -p "${hook_dir}"

    cat > "${hook_dir}/20-secureboot-sign" << 'HOOKEOF'
#!/bin/sh
# Auto-sign kernel after installation (Secure Boot MOK)
KEY_DIR="/root/secureboot"
[ -f "${KEY_DIR}/MOK.priv" ] || exit 0

KERNEL="/boot/vmlinuz-${1}"
[ -f "${KERNEL}" ] || exit 0

# Only sign if sbsign is available
command -v sbsign >/dev/null 2>&1 || exit 0

sbsign --key "${KEY_DIR}/MOK.priv" --cert "${KEY_DIR}/MOK.pem" \
    --output "${KERNEL}" "${KERNEL}" 2>/dev/null
HOOKEOF
    chmod +x "${hook_dir}/20-secureboot-sign"

    einfo "Kernel signing hook installed at ${hook_dir}/20-secureboot-sign"
}
