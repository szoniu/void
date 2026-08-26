#!/usr/bin/env bash
# bootloader.sh — GRUB installation, os-prober, dual-boot, EFI verification
source "${LIB_DIR}/protection.sh"

# bootloader_install — Install and configure GRUB
bootloader_install() {
    einfo "Installing bootloader (GRUB)..."

    # Install GRUB for x86_64 EFI
    try "Installing GRUB" xbps-install -y grub-x86_64-efi

    # Install os-prober for dual-boot detection
    if [[ "${WINDOWS_DETECTED:-0}" == "1" ]] || [[ "${LINUX_DETECTED:-0}" == "1" ]] || \
       [[ "${ESP_REUSE:-no}" == "yes" ]]; then
        try "Installing os-prober" xbps-install -y os-prober
    fi

    # Install efibootmgr for EFI entry management
    try "Installing efibootmgr" xbps-install -y efibootmgr

    # Install GRUB to ESP
    local grub_target="/boot/efi"
    local grub_id="Void"

    # Apple firmware rebuilds its boot list from its own bless database and
    # does not reliably persist UEFI NVRAM entries, so a normal grub-install
    # leaves the Mac unable to find GRUB after a reboot. There the removable
    # path (\EFI\BOOT\BOOTX64.EFI, always tried by Apple firmware) is the
    # PRIMARY install and the NVRAM entry is best-effort: efibootmgr failing
    # on a Mac must not drop the user into the try() recovery menu.
    if [[ "${APPLE_DETECTED:-0}" == "1" ]]; then
        einfo "Apple Mac — installing GRUB to the removable path (BOOTX64.EFI)"
        try "Installing GRUB to ESP (Apple removable path)" \
            grub-install --target=x86_64-efi --efi-directory="${grub_target}" \
            --bootloader-id="${grub_id}" --removable --recheck
        # Secondary, best-effort: a named entry for firmware that does keep it
        grub-install --target=x86_64-efi --efi-directory="${grub_target}" \
            --bootloader-id="${grub_id}" --recheck &>/dev/null || true
    else
        try "Installing GRUB to ESP" \
            grub-install --target=x86_64-efi --efi-directory="${grub_target}" \
            --bootloader-id="${grub_id}" --recheck
    fi

    # Configure GRUB
    _configure_grub

    # Mount other OS partitions so os-prober can find them
    _mount_other_oses_for_osprober

    # Generate GRUB config
    try "Generating GRUB configuration" grub-mkconfig -o /boot/grub/grub.cfg

    # btrfs safety net: if 10_linux somehow did not add rootflags=subvol=, the
    # kernel would mount the btrfs top level and never find the system. Add it
    # explicitly and regenerate — but only in that case, to avoid a duplicate.
    if [[ "${FILESYSTEM:-}" == "btrfs" ]] && \
       ! grep -q 'rootflags=subvol=' /boot/grub/grub.cfg 2>/dev/null; then
        ewarn "grub-mkconfig did not add rootflags=subvol= — injecting it manually"
        if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub 2>/dev/null; then
            sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="rootflags=subvol=@"|' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX="rootflags=subvol=@"' >> /etc/default/grub
        fi
        try "Re-generating GRUB configuration (btrfs rootflags)" \
            grub-mkconfig -o /boot/grub/grub.cfg
    fi

    # Verify GRUB detected all known operating systems
    _verify_grub_config

    # Unmount os-prober mounts
    _unmount_osprober_mounts

    # Verify EFI boot entries
    _verify_efi_entries

    einfo "Bootloader installation complete"
}

# _configure_grub — Set up /etc/default/grub
_configure_grub() {
    einfo "Configuring GRUB..."

    local grub_default="/etc/default/grub"
    local root_uuid
    root_uuid=$(get_uuid "${ROOT_PARTITION}")

    local root_param=""
    if [[ -n "${root_uuid}" ]]; then
        root_param="root=UUID=${root_uuid}"
    else
        root_param="root=${ROOT_PARTITION}"
    fi

    # LUKS: GRUB itself must open the container, because /boot lives on the
    # encrypted root. Without GRUB_ENABLE_CRYPTODISK the firmware loads GRUB,
    # GRUB finds no readable filesystem and drops to a rescue prompt.
    local luks_params=""
    if [[ "${LUKS_ENABLED:-no}" == "yes" ]] && declare -F luks_grub_cmdline >/dev/null; then
        luks_params=$(luks_grub_cmdline) || true
    fi

    # Filesystem-specific parameters. NOTE: rootflags=subvol= is deliberately
    # NOT set here — GRUB's 10_linux detects the mounted subvolume and injects
    # it itself, so hardcoding it puts the option on the cmdline twice. The
    # safety net after grub-mkconfig (below) adds it only if 10_linux did not.
    local extra_params=""

    # Default kernel cmdline (the "quiet" line). UMPC portrait-panel quirk:
    # fbcon for early console + panel_orientation override for KMS so the
    # framebuffer console, GRUB and the Plasma Wayland session all come up
    # rotated on first boot (GPD Pocket 4, Chuwi MiniBook X, ...).
    local default_params="quiet loglevel=3"
    if [[ "${UMPC_DETECTED:-0}" == "1" ]] && [[ -n "${UMPC_PANEL_ORIENTATION:-}" ]]; then
        default_params="${default_params} fbcon=rotate:${UMPC_FBCON_ROTATE} video=${UMPC_VIDEO_CONNECTOR}:panel_orientation=${UMPC_PANEL_ORIENTATION}"
        einfo "UMPC panel rotation applied to GRUB_CMDLINE_LINUX_DEFAULT"
    fi

    cat > "${grub_default}" << GRUBEOF
# /etc/default/grub
# Generated by ${INSTALLER_NAME} v${INSTALLER_VERSION}

GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Void"

GRUB_CMDLINE_LINUX_DEFAULT="${default_params}"
GRUB_CMDLINE_LINUX="${extra_params}${luks_params:+${extra_params:+ }${luks_params}}"

# Console settings
GRUB_TERMINAL_INPUT="console"
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_GFXMODE="auto"
GRUB_GFXPAYLOAD_LINUX="keep"
GRUBEOF

    if [[ "${LUKS_ENABLED:-no}" == "yes" ]]; then
        cat >> "${grub_default}" << 'LUKSEOF'

# Encrypted root: GRUB has to unlock the container to read /boot
GRUB_ENABLE_CRYPTODISK=y
LUKSEOF
        einfo "GRUB configured for an encrypted root (cryptodisk enabled)"
    fi

    # Dual-boot: enable os-prober
    if [[ "${WINDOWS_DETECTED:-0}" == "1" ]] || [[ "${LINUX_DETECTED:-0}" == "1" ]] || \
       [[ "${ESP_REUSE:-no}" == "yes" ]]; then
        cat >> "${grub_default}" << DUALEOF

# Dual-boot: os-prober enabled
GRUB_DISABLE_OS_PROBER=false
DUALEOF
        einfo "os-prober enabled for dual-boot detection"
    fi

    einfo "GRUB configured"
}

# _mount_other_oses_for_osprober — Temporarily mount detected OS partitions
# so os-prober can find them during grub-mkconfig
_mount_other_oses_for_osprober() {
    declare -ga _OSPROBER_MOUNTS=()

    # Nothing to do if no other OSes detected
    [[ ${#DETECTED_OSES[@]} -eq 0 ]] && return 0

    einfo "Mounting other OS partitions for os-prober..."

    local part
    for part in "${!DETECTED_OSES[@]}"; do
        # Skip our own partitions
        [[ "${part}" == "${ESP_PARTITION:-}" ]] && continue
        [[ "${part}" == "${ROOT_PARTITION:-}" ]] && continue
        [[ "${part}" == "${WINDOWS_ESP:-}" ]] && continue

        # Skip if already mounted
        if findmnt -n "${part}" &>/dev/null; then
            einfo "  ${part} already mounted, skipping"
            continue
        fi

        local partname="${part##*/}"
        local mpoint="/mnt/osprober-${partname}"
        mkdir -p "${mpoint}"

        if mount -o ro "${part}" "${mpoint}" 2>/dev/null; then
            _OSPROBER_MOUNTS+=("${mpoint}")
            einfo "  Mounted ${part} at ${mpoint}"
        else
            rmdir "${mpoint}" 2>/dev/null || true
        fi
    done
}

# _unmount_osprober_mounts — Clean up temporary os-prober mounts
_unmount_osprober_mounts() {
    local mpoint
    for mpoint in "${_OSPROBER_MOUNTS[@]}"; do
        umount "${mpoint}" 2>/dev/null || true
        rmdir "${mpoint}" 2>/dev/null || true
    done
    _OSPROBER_MOUNTS=()
}

# _verify_grub_config — Check that grub.cfg contains entries for all detected OSes
_verify_grub_config() {
    local grub_cfg="/boot/grub/grub.cfg"
    [[ ! -f "${grub_cfg}" ]] && return 0
    [[ ${#DETECTED_OSES[@]} -eq 0 ]] && return 0

    einfo "Verifying GRUB configuration..."

    local -a missing_oses=()
    local part

    for part in "${!DETECTED_OSES[@]}"; do
        # Skip our own root partition
        [[ "${part}" == "${ROOT_PARTITION:-}" ]] && continue

        local os_name="${DETECTED_OSES[${part}]}"
        local found=0

        # For Windows: check for 'windows' (case-insensitive)
        if [[ "${os_name}" == *"Windows"* ]]; then
            if grep -qi 'windows' "${grub_cfg}" 2>/dev/null; then
                found=1
            fi
        else
            # For Linux: search for first word of OS name or partition UUID
            local first_word="${os_name%% *}"
            if grep -qi "${first_word}" "${grub_cfg}" 2>/dev/null; then
                found=1
            else
                # Try partition UUID
                local part_uuid
                part_uuid=$(get_uuid "${part}" 2>/dev/null) || true
                if [[ -n "${part_uuid}" ]] && grep -q "${part_uuid}" "${grub_cfg}" 2>/dev/null; then
                    found=1
                fi
            fi
        fi

        if [[ "${found}" -eq 0 ]]; then
            missing_oses+=("${part}: ${os_name}")
        fi
    done

    if [[ ${#missing_oses[@]} -eq 0 ]]; then
        einfo "GRUB configuration verified — all detected OSes found"
        return 0
    fi

    # Some OSes are missing from grub.cfg
    local missing_text=""
    local entry
    for entry in "${missing_oses[@]}"; do
        missing_text+="  ${entry}\n"
    done

    ewarn "GRUB may not have detected all operating systems:"
    ewarn "${missing_text}"

    # Interactive recovery menu
    if command -v "${DIALOG_CMD:-dialog}" &>/dev/null; then
        local choice
        choice=$(dialog_menu "Missing OS in GRUB" \
            "rerun"   "Re-run grub-mkconfig" \
            "continue" "Continue anyway (can fix later)" \
            "shell"   "Drop to shell") || choice="continue"

        case "${choice}" in
            rerun)
                _mount_other_oses_for_osprober
                try "Re-generating GRUB configuration" grub-mkconfig -o /boot/grub/grub.cfg
                _unmount_osprober_mounts
                ;;
            shell)
                ewarn "Type 'exit' to return to the installer"
                bash --norc --noprofile || true
                ;;
            continue)
                einfo "Continuing with current GRUB configuration"
                ;;
        esac
    else
        # Text fallback for chroot without dialog
        echo ""
        echo "WARNING: Some operating systems may be missing from GRUB:"
        echo -e "${missing_text}"
        echo "(r)e-run grub-mkconfig | (c)ontinue | (s)hell"
        local reply
        read -r reply < /dev/tty 2>/dev/null || reply="c"
        case "${reply}" in
            r)
                _mount_other_oses_for_osprober
                try "Re-generating GRUB configuration" grub-mkconfig -o /boot/grub/grub.cfg
                _unmount_osprober_mounts
                ;;
            s)
                ewarn "Type 'exit' to return to the installer"
                bash --norc --noprofile || true
                ;;
            *)
                einfo "Continuing with current GRUB configuration"
                ;;
        esac
    fi
}

# _verify_efi_entries — Check EFI boot entries for expected bootloaders
_verify_efi_entries() {
    # Only relevant on EFI systems
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would verify EFI boot entries"
        return 0
    fi

    if ! command -v efibootmgr &>/dev/null; then
        ewarn "efibootmgr not available — skipping EFI entry verification"
        return 0
    fi

    einfo "Verifying EFI boot entries..."

    local efi_output
    efi_output=$(efibootmgr 2>/dev/null) || true

    if [[ -z "${efi_output}" ]]; then
        ewarn "Could not read EFI boot entries"
        return 0
    fi

    elog "EFI boot entries:\n${efi_output}"

    # Check for Void entry
    if ! echo "${efi_output}" | grep -qi 'void'; then
        ewarn "No Void EFI boot entry found — boot may fail"
    else
        einfo "Void EFI boot entry present"
    fi

    # Check for Windows Boot Manager if Windows was detected
    if [[ "${WINDOWS_DETECTED:-0}" == "1" ]]; then
        if ! echo "${efi_output}" | grep -qi 'windows'; then
            ewarn "WARNING: Windows Boot Manager EFI entry not found!"
            ewarn "Windows may not appear in firmware boot menu."
            ewarn "It should still be accessible via GRUB os-prober."
        else
            einfo "Windows Boot Manager EFI entry present"
        fi
    fi
}
