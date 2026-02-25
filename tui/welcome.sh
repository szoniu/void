#!/usr/bin/env bash
# tui/welcome.sh — Welcome screen + prerequisite checks
source "${LIB_DIR}/protection.sh"

# screen_welcome — First wizard screen
# Returns: TUI_NEXT (0), TUI_BACK (1), TUI_ABORT (2)
screen_welcome() {
    local welcome_text
    welcome_text="Welcome to ${INSTALLER_NAME} v${INSTALLER_VERSION}

This wizard will guide you through installing Void Linux
with KDE Plasma desktop.

The installer will:
  * Detect hardware (CPU, GPU, disks)
  * Partition and format disk
  * Install Void rootfs and configure XBPS
  * Install kernel, set up KDE Plasma + SDDM
  * Configure GRUB bootloader (dual-boot supported)

Requirements:
  * Root access           * UEFI boot mode
  * Internet connection   * 20 GiB+ free disk space

Press OK to check prerequisites and continue."

    dialog_msgbox "Welcome" "${welcome_text}" || return "${TUI_ABORT}"

    # Check prerequisites
    local -a errors=()
    local -a warnings=()

    # Root check
    if ! is_root; then
        errors+=("Not running as root. Please run with sudo or as root.")
    fi

    # EFI check
    if ! is_efi; then
        errors+=("System is not booted in UEFI mode. This installer requires UEFI.")
    fi

    # Network check
    if ! has_network; then
        warnings+=("No network connectivity detected. You will need internet for installation.")
    fi

    # Dialog/whiptail check (already running if we got here, but verify)
    if [[ -z "${DIALOG_CMD:-}" ]]; then
        errors+=("No dialog backend available.")
    fi

    # Build error/warning message
    local status_text=""
    local has_errors=0

    status_text+="Prerequisite Check Results:\n\n"

    # Show passes
    if is_root 2>/dev/null; then
        status_text+="  [OK] Running as root\n"
    fi
    if is_efi 2>/dev/null; then
        status_text+="  [OK] UEFI boot mode detected\n"
    fi
    if has_network 2>/dev/null; then
        status_text+="  [OK] Network connectivity\n"
    fi
    status_text+="  [OK] Dialog backend: ${DIALOG_CMD:-unknown}\n"

    # Show warnings
    local w
    for w in "${warnings[@]}"; do
        status_text+="\n  [!!] ${w}\n"
    done

    # Show errors
    local e
    for e in "${errors[@]}"; do
        status_text+="\n  [FAIL] ${e}\n"
        has_errors=1
    done

    if [[ ${has_errors} -eq 1 ]]; then
        status_text+="\nCritical errors found. Installation cannot proceed."
        dialog_msgbox "Prerequisites — FAILED" "${status_text}"

        if [[ "${FORCE:-0}" != "1" ]]; then
            return "${TUI_ABORT}"
        fi

        # Force mode — warn but continue
        dialog_yesno "Force Mode" \
            "Prerequisites failed but --force is set.\n\nContinue anyway? This may cause errors." \
            || return "${TUI_ABORT}"
    else
        if [[ ${#warnings[@]} -gt 0 ]]; then
            status_text+="\nWarnings found but installation can proceed."
            dialog_yesno "Prerequisites — Warnings" "${status_text}" \
                || return "${TUI_ABORT}"
        else
            status_text+="\nAll prerequisites passed!"
            dialog_msgbox "Prerequisites — OK" "${status_text}"
        fi
    fi

    return "${TUI_NEXT}"
}
