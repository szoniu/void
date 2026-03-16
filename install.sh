#!/usr/bin/env bash
# install.sh — Main entry point for the Void Linux TUI Installer
#
# Usage:
#   ./install.sh              — Run full installation (TUI wizard + install)
#   ./install.sh --configure  — Run only the TUI wizard (generate config)
#   ./install.sh --install    — Run only the installation (using existing config)
#   ./install.sh --dry-run    — Run wizard + simulate installation
#   ./install.sh __chroot_phase — (Internal) Run chroot phase
#
set -euo pipefail
shopt -s inherit_errexit

# Mark as the Void installer (used by protection.sh)
export _VOID_INSTALLER=1

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export LIB_DIR="${SCRIPT_DIR}/lib"
export TUI_DIR="${SCRIPT_DIR}/tui"
export DATA_DIR="${SCRIPT_DIR}/data"

# --- Source library modules ---
source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/disk.sh"
source "${LIB_DIR}/network.sh"
source "${LIB_DIR}/rootfs.sh"
source "${LIB_DIR}/xbps.sh"
source "${LIB_DIR}/kernel.sh"
source "${LIB_DIR}/bootloader.sh"
source "${LIB_DIR}/system.sh"
source "${LIB_DIR}/desktop.sh"
source "${LIB_DIR}/swap.sh"
source "${LIB_DIR}/chroot.sh"
source "${LIB_DIR}/hooks.sh"
source "${LIB_DIR}/preset.sh"

# --- Source TUI screens ---
source "${TUI_DIR}/welcome.sh"
source "${TUI_DIR}/preset_load.sh"
source "${TUI_DIR}/hw_detect.sh"
source "${TUI_DIR}/disk_select.sh"
source "${TUI_DIR}/filesystem_select.sh"
source "${TUI_DIR}/swap_config.sh"
source "${TUI_DIR}/network_config.sh"
source "${TUI_DIR}/locale_config.sh"
source "${TUI_DIR}/kernel_select.sh"
source "${TUI_DIR}/gpu_config.sh"
source "${TUI_DIR}/desktop_config.sh"
source "${TUI_DIR}/user_config.sh"
source "${TUI_DIR}/extra_packages.sh"
source "${TUI_DIR}/preset_save.sh"
source "${TUI_DIR}/summary.sh"
source "${TUI_DIR}/progress.sh"

# --- Source data files ---
source "${DATA_DIR}/gpu_database.sh"
source "${DATA_DIR}/mirrors.sh"

# --- Cleanup trap ---
cleanup() {
    local rc=$?

    # Restore terminal echo (gum backend may disable it)
    stty echo </dev/tty 2>/dev/null || true

    # Restore stderr if it was redirected to log file (fd 4 saved by screen_progress)
    if { true >&4; } 2>/dev/null; then
        exec 2>&4
        exec 4>&-
    fi

    if [[ "${_IN_CHROOT:-0}" != "1" ]]; then
        # Only do cleanup in outer process
        if mountpoint -q "${MOUNTPOINT}/proc" 2>/dev/null; then
            ewarn "Cleaning up mount points..."
            chroot_teardown || true
        fi
    fi
    if [[ ${rc} -ne 0 ]]; then
        eerror "Installer exited with code ${rc}"
        eerror "Log file: ${LOG_FILE}"
    fi
    return ${rc}
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM

# --- Parse arguments ---
MODE="full"
DRY_RUN=0
FORCE=0
NON_INTERACTIVE=0
export DRY_RUN FORCE NON_INTERACTIVE

usage() {
    cat <<'EOF'
Void Linux TUI Installer

Usage:
  install.sh [OPTIONS] [COMMAND]

Commands:
  (default)       Run full installation (wizard + install)
  --configure     Run only the TUI configuration wizard
  --install       Run only the installation phase (requires config)
  --resume        Resume interrupted installation (scan disks for checkpoints)
  __chroot_phase  Internal: execute chroot phase

Options:
  --config FILE   Use specified config file
  --dry-run       Simulate installation without destructive operations
  --force         Continue past failed prerequisite checks
  --non-interactive  Abort on any error (no recovery menu)
  --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configure)
            MODE="configure"
            shift
            ;;
        --install)
            MODE="install"
            shift
            ;;
        --resume)
            MODE="resume"
            shift
            ;;
        __chroot_phase)
            MODE="chroot"
            shift
            ;;
        --config)
            if [[ $# -lt 2 ]]; then
                die "--config requires a file argument"
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            eerror "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# --- Main functions ---

# run_configuration_wizard — Launch all TUI screens
run_configuration_wizard() {
    init_dialog

    register_wizard_screens \
        screen_welcome \
        screen_preset_load \
        screen_hw_detect \
        screen_disk_select \
        screen_filesystem_select \
        screen_swap_config \
        screen_network_config \
        screen_locale_config \
        screen_kernel_select \
        screen_gpu_config \
        screen_desktop_config \
        screen_user_config \
        screen_extra_packages \
        screen_preset_save \
        screen_summary

    run_wizard

    config_save "${CONFIG_FILE}"
    einfo "Configuration complete. Saved to ${CONFIG_FILE}"
}

# run_chroot_phase — Execute inside chroot (re-invoked by install.sh __chroot_phase)
run_chroot_phase() {
    if [[ "${_IN_CHROOT:-0}" == "1" ]]; then
        _do_chroot_phases
    else
        # Re-invoke ourselves inside chroot
        chroot_exec "${CHROOT_INSTALLER_DIR}/install.sh" __chroot_phase \
            --config "${CHROOT_INSTALLER_DIR}/$(basename "${CONFIG_FILE}")"
    fi
}

# _do_chroot_phases — Actual chroot work
_do_chroot_phases() {
    export _IN_CHROOT=1
    einfo "=== Chroot installation phases ==="

    # Phase 5: XBPS update + base-system
    if ! checkpoint_reached "xbps_update"; then
        einfo "--- Phase: XBPS update ---"
        maybe_exec 'before_xbps_update'
        xbps_update
        maybe_exec 'after_xbps_update'
        checkpoint_set "xbps_update"
    else
        einfo "Skipping xbps update (checkpoint reached)"
    fi

    # Phase 6: System config
    if ! checkpoint_reached "system_config"; then
        einfo "--- Phase: System configuration ---"
        maybe_exec 'before_system_config'
        system_set_timezone
        system_set_locale
        system_set_hostname
        system_set_keymap
        maybe_exec 'after_system_config'
        checkpoint_set "system_config"
    else
        einfo "Skipping system config (checkpoint reached)"
    fi

    # Phase 7: Kernel
    if ! checkpoint_reached "kernel"; then
        einfo "--- Phase: Kernel ---"
        maybe_exec 'before_kernel'
        kernel_install
        maybe_exec 'after_kernel'
        checkpoint_set "kernel"
    else
        einfo "Skipping kernel (checkpoint reached)"
    fi

    # Phase 8: Filesystem tools + fstab
    if ! checkpoint_reached "fstab"; then
        einfo "--- Phase: Filesystem tools and fstab ---"
        maybe_exec 'before_fstab'
        install_filesystem_tools
        generate_fstab
        maybe_exec 'after_fstab'
        checkpoint_set "fstab"
    else
        einfo "Skipping fstab (checkpoint reached)"
    fi

    # Phase 9: Networking
    if ! checkpoint_reached "networking"; then
        einfo "--- Phase: Networking ---"
        maybe_exec 'before_networking'
        install_network_manager
        maybe_exec 'after_networking'
        checkpoint_set "networking"
    else
        einfo "Skipping networking (checkpoint reached)"
    fi

    # Phase 10: Bootloader
    if ! checkpoint_reached "bootloader"; then
        einfo "--- Phase: Bootloader ---"
        maybe_exec 'before_bootloader'
        bootloader_install
        maybe_exec 'after_bootloader'
        checkpoint_set "bootloader"
    else
        einfo "Skipping bootloader (checkpoint reached)"
    fi

    # Phase 11: Swap
    if ! checkpoint_reached "swap_setup"; then
        einfo "--- Phase: Swap ---"
        maybe_exec 'before_swap'
        swap_setup
        maybe_exec 'after_swap'
        checkpoint_set "swap_setup"
    else
        einfo "Skipping swap setup (checkpoint reached)"
    fi

    # Phase 12: Desktop
    if ! checkpoint_reached "desktop"; then
        einfo "--- Phase: Desktop ---"
        maybe_exec 'before_desktop'
        desktop_install
        maybe_exec 'after_desktop'
        checkpoint_set "desktop"
    else
        einfo "Skipping desktop (checkpoint reached)"
    fi

    # Phase 13: Users
    if ! checkpoint_reached "users"; then
        einfo "--- Phase: Users ---"
        maybe_exec 'before_users'
        system_create_users
        maybe_exec 'after_users'
        checkpoint_set "users"
    else
        einfo "Skipping users (checkpoint reached)"
    fi

    # Phase 14: Extras
    if ! checkpoint_reached "extras"; then
        einfo "--- Phase: Extra packages ---"
        maybe_exec 'before_extras'
        xbps_install_base
        install_extra_packages
        install_hyprland_ecosystem
        install_noctalia_shell
        install_fingerprint_tools
        install_thunderbolt_tools
        install_sensor_tools
        install_wwan_tools
        install_asusctl_tools
        maybe_exec 'after_extras'
        checkpoint_set "extras"
    else
        einfo "Skipping extras (checkpoint reached)"
    fi

    # Phase 15: Finalize
    if ! checkpoint_reached "finalize"; then
        einfo "--- Phase: Finalization ---"
        maybe_exec 'before_finalize'
        system_finalize
        maybe_exec 'after_finalize'
        checkpoint_set "finalize"
    else
        einfo "Skipping finalization (checkpoint reached)"
    fi

    einfo "=== All chroot phases complete ==="
}

# run_post_install — Final steps after chroot
run_post_install() {
    einfo "=== Post-installation ==="

    # Unmount everything
    unmount_filesystems

    if dialog_yesno "Reboot" "Would you like to reboot now?"; then
        einfo "Rebooting..."
        if [[ "${DRY_RUN}" != "1" ]]; then
            reboot
        else
            einfo "[DRY-RUN] Would reboot now"
        fi
    else
        einfo "You can reboot manually when ready."
        einfo "Log file: ${LOG_FILE}"
    fi
}

# preflight_checks — Verify system readiness
preflight_checks() {
    einfo "Running preflight checks..."

    if [[ "${DRY_RUN}" != "1" ]]; then
        is_root || die "Must run as root"
        is_efi || die "UEFI boot mode required"
        ensure_dns
        has_network || die "Network connectivity required"
    fi

    # Sync clock (skip if NTP daemon already running)
    if [[ "${DRY_RUN}" != "1" ]]; then
        if pgrep -x chronyd &>/dev/null || pgrep -x ntpd &>/dev/null; then
            einfo "NTP daemon already running, clock should be synced"
        elif command -v chronyc &>/dev/null; then
            chronyc makestep &>/dev/null || chronyd -q &>/dev/null || true
            einfo "Clock synced via chrony"
        elif command -v ntpdate &>/dev/null; then
            try "Syncing system clock" ntpdate pool.ntp.org || true
        elif ntpd --help 2>&1 | grep -q 'step'; then
            try "Syncing system clock" ntpd -q -g || true
        fi
    fi

    einfo "Preflight checks passed"
}

# --- Entry point ---
main() {
    init_logging

    einfo "========================================="
    einfo "${INSTALLER_NAME} v${INSTALLER_VERSION}"
    einfo "========================================="
    einfo "Mode: ${MODE}"
    [[ "${DRY_RUN}" == "1" ]] && ewarn "DRY-RUN mode enabled"

    case "${MODE}" in
        full)
            run_configuration_wizard
            screen_progress
            run_post_install
            ;;
        configure)
            run_configuration_wizard
            ;;
        install)
            config_load "${CONFIG_FILE}"
            deserialize_detected_oses
            init_dialog
            screen_progress
            run_post_install
            ;;
        resume)
            local resume_rc=0
            try_resume_from_disk || resume_rc=$?

            case ${resume_rc} in
                0)
                    # Config + checkpoints recovered
                    config_load "${CONFIG_FILE}"
                    deserialize_detected_oses
                    init_dialog

                    # Show recovered checkpoints
                    local completed_list=""
                    local cp_name
                    for cp_name in "${CHECKPOINTS[@]}"; do
                        if checkpoint_reached "${cp_name}"; then
                            completed_list+="  - ${cp_name}\n"
                        fi
                    done
                    dialog_msgbox "Resume: Data Recovered" \
                        "Found previous installation on ${RESUME_FOUND_PARTITION}.\n\nRecovered config and checkpoints:\n\n${completed_list}\nResuming installation..."

                    screen_progress
                    run_post_install
                    ;;
                1)
                    # Only checkpoints, no config — try inference from partition
                    init_dialog

                    local infer_rc=0
                    infer_config_from_partition "${RESUME_FOUND_PARTITION}" "${RESUME_FOUND_FSTYPE}" || infer_rc=$?

                    if [[ ${infer_rc} -eq 0 ]]; then
                        # Sufficient config inferred — save and proceed
                        config_save "${CONFIG_FILE}"

                        local inferred_summary=""
                        inferred_summary+="Partition: ${ROOT_PARTITION:-?}\n"
                        inferred_summary+="Disk: ${TARGET_DISK:-?}\n"
                        inferred_summary+="Filesystem: ${FILESYSTEM:-?}\n"
                        inferred_summary+="ESP: ${ESP_PARTITION:-?}\n"
                        [[ -n "${HOSTNAME:-}" ]] && inferred_summary+="Hostname: ${HOSTNAME}\n"
                        [[ -n "${TIMEZONE:-}" ]] && inferred_summary+="Timezone: ${TIMEZONE}\n"
                        [[ -n "${LOCALE:-}" ]] && inferred_summary+="Locale: ${LOCALE}\n"
                        [[ -n "${KERNEL_TYPE:-}" ]] && inferred_summary+="Kernel: ${KERNEL_TYPE}\n"
                        [[ -n "${GPU_VENDOR:-}" ]] && inferred_summary+="GPU: ${GPU_VENDOR}\n"

                        local completed_list=""
                        local cp_name
                        for cp_name in "${CHECKPOINTS[@]}"; do
                            if checkpoint_reached "${cp_name}"; then
                                completed_list+="  - ${cp_name}\n"
                            fi
                        done

                        dialog_msgbox "Resume: Config Inferred" \
                            "Found checkpoints on ${RESUME_FOUND_PARTITION} (no config file).\n\nInferred configuration:\n${inferred_summary}\nCompleted phases:\n${completed_list}\nResuming installation..."

                        screen_progress
                        run_post_install
                    else
                        # Partial inference — pre-filled wizard
                        dialog_msgbox "Resume: Partial Recovery" \
                            "Found checkpoints on ${RESUME_FOUND_PARTITION} but could not fully infer configuration.\n\nSome fields have been pre-filled from the installed system.\nPlease complete the wizard. Completed phases will be skipped automatically."

                        run_configuration_wizard
                        screen_progress
                        run_post_install
                    fi
                    ;;
                2)
                    # Nothing found — fall back to full mode
                    init_dialog
                    dialog_msgbox "Resume: Nothing Found" \
                        "No previous installation data found on any partition.\n\nStarting full installation."

                    run_configuration_wizard
                    screen_progress
                    run_post_install
                    ;;
            esac
            ;;
        chroot)
            # Running inside chroot
            export _IN_CHROOT=1
            config_load "${CONFIG_FILE}"
            deserialize_detected_oses
            _do_chroot_phases
            ;;
        *)
            die "Unknown mode: ${MODE}"
            ;;
    esac

    einfo "Done."
}

main "$@"
