#!/usr/bin/env bash
# tui/secureboot_config.sh — Secure Boot (MOK signing) configuration
source "${LIB_DIR}/protection.sh"

screen_secureboot_config() {
    # Only show on EFI systems
    if [[ "${DRY_RUN:-0}" != "1" ]] && ! is_efi; then
        ENABLE_SECUREBOOT="no"
        export ENABLE_SECUREBOOT
        return "${TUI_NEXT}"
    fi

    local sb_active=0
    is_secureboot_active && sb_active=1

    local sb_text=""
    sb_text+="Enable Secure Boot signing?\n\n"
    sb_text+="This will:\n"
    sb_text+="  - Generate MOK (Machine Owner Key) signing keys\n"
    sb_text+="  - Sign the kernel and GRUB bootloader\n"
    sb_text+="  - Download and set up shim as chainloader\n"
    sb_text+="  - Install kernel signing hook for future updates\n\n"
    if [[ ${sb_active} -eq 1 ]]; then
        sb_text+="At first reboot, MokManager will appear.\n"
        sb_text+="Select 'Enroll MOK', verify the key, and enter\n"
        sb_text+="password: void\n\n"
    else
        sb_text+="NOTE: Secure Boot is currently DISABLED.\n"
        sb_text+="After installation:\n"
        sb_text+="  1. Enable Secure Boot in BIOS/UEFI\n"
        sb_text+="  2. Reboot — MokManager will appear\n"
        sb_text+="  3. Select 'Enroll MOK' -> password: void\n\n"
    fi
    sb_text+="Required packages: sbsigntool, openssl\n"
    sb_text+="Shim will be downloaded from Fedora (signed by Microsoft)."

    local rc=0
    dialog_yesno "Secure Boot" "${sb_text}" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        ENABLE_SECUREBOOT="yes"
    elif [[ ${rc} -eq 1 ]]; then
        ENABLE_SECUREBOOT="no"
    else
        # ESC / abort — go back
        return "${TUI_BACK}"
    fi

    export ENABLE_SECUREBOOT
    einfo "Secure Boot: ${ENABLE_SECUREBOOT}"
    return "${TUI_NEXT}"
}
