#!/usr/bin/env bash
# tui/progress.sh — Installation progress screen (all within dialog UI)
source "${LIB_DIR}/protection.sh"

# Phase definitions: "phase_name|description"
readonly -a INSTALL_PHASES=(
    "preflight|Preflight checks"
    "disks|Disk operations"
    "rootfs_download|Downloading ROOTFS"
    "rootfs_verify|Verifying ROOTFS"
    "rootfs_extract|Extracting ROOTFS"
    "xbps_preconfig|XBPS pre-configuration"
    "chroot|Chroot phases"
)

# _save_config_to_target — Persist config file to target disk for --resume recovery
_save_config_to_target() {
    if [[ -n "${MOUNTPOINT:-}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null; then
        config_save "${MOUNTPOINT}/tmp/$(basename "${CONFIG_FILE}")"
    fi
}

# _detect_and_handle_resume — Check for previous progress and ask user
# Returns 0 if resuming, 1 if starting fresh
_detect_and_handle_resume() {
    local has_checkpoints=0

    # Check /tmp checkpoints
    if [[ -d "${CHECKPOINT_DIR}" ]] && ls "${CHECKPOINT_DIR}/"* &>/dev/null 2>&1; then
        has_checkpoints=1
    fi

    # Check target disk checkpoints
    local target_checkpoint_dir="${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}"
    if [[ -d "${target_checkpoint_dir}" ]] && ls "${target_checkpoint_dir}/"* &>/dev/null 2>&1; then
        has_checkpoints=1
        # Adopt target checkpoints if they exist and /tmp ones don't
        if [[ ! -d "${CHECKPOINT_DIR}" ]] || ! ls "${CHECKPOINT_DIR}/"* &>/dev/null 2>&1; then
            CHECKPOINT_DIR="${target_checkpoint_dir}"
            export CHECKPOINT_DIR
        fi
    fi

    if [[ "${has_checkpoints}" -eq 0 ]]; then
        return 1  # no previous progress
    fi

    # List completed checkpoints for display
    local completed_list=""
    local cp_name
    for cp_name in "${CHECKPOINTS[@]}"; do
        if checkpoint_reached "${cp_name}"; then
            completed_list+="  - ${cp_name}\n"
        fi
    done

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        # Non-interactive: default to resume
        einfo "Non-interactive mode — resuming from previous progress"
        _validate_and_clean_checkpoints
        return 0
    fi

    if dialog_yesno "Resume Installation" \
        "Previous installation progress detected:\n\n${completed_list}\nResume from where it left off?\n\nChoose 'No' to start fresh (all progress will be lost)."; then
        _validate_and_clean_checkpoints
        return 0
    else
        checkpoint_clear
        return 1
    fi
}

# _validate_and_clean_checkpoints — Validate each checkpoint, remove invalid ones
_validate_and_clean_checkpoints() {
    local cp_name
    for cp_name in "${CHECKPOINTS[@]}"; do
        if checkpoint_reached "${cp_name}" && ! checkpoint_validate "${cp_name}"; then
            ewarn "Checkpoint '${cp_name}' failed validation — will re-run"
            rm -f "${CHECKPOINT_DIR}/${cp_name}"
        fi
    done
}

# screen_progress — Run installation with dialog_infobox status display
screen_progress() {
    local total=${#INSTALL_PHASES[@]}
    local i=0

    # Mount filesystems early so checkpoint validation can inspect target disk
    # contents. Best-effort, but NOT silenced: a failure here (e.g. a stale or
    # wrong ROOT_PARTITION from an inferred --resume config) must be visible in
    # the log. We only attempt when ROOT_PARTITION is a real block device;
    # checkpoint_validate "disks" then invalidates the disks checkpoint when
    # the mount did not succeed, so the disks phase safely re-runs instead of
    # the installer proceeding onto an unmounted/wrong target.
    # An encrypted root has to be unlocked before anything can be mounted —
    # ROOT_PARTITION points at /dev/mapper/<name>, which does not exist until
    # the container is open.
    if [[ "${LUKS_ENABLED:-no}" == "yes" ]] && declare -F luks_open_for_resume >/dev/null; then
        luks_open_for_resume || ewarn "Could not open the LUKS container"
    fi

    if ! mountpoint -q "${MOUNTPOINT}" 2>/dev/null && \
       { checkpoint_reached "disks" || \
         { [[ "${MODE:-}" == "resume" ]] && _resume_target_has_system; }; }; then
        if [[ -b "${ROOT_PARTITION:-}" ]]; then
            if ! mount_filesystems; then
                ewarn "Early mount of ${ROOT_PARTITION} failed — disks checkpoint will be re-validated"
            fi
        else
            ewarn "ROOT_PARTITION '${ROOT_PARTITION:-unset}' is not a block device — skipping early mount"
        fi
    fi

    # Check for previous progress and handle resume
    if ! _detect_and_handle_resume; then
        einfo "Starting fresh installation"
    else
        einfo "Resuming installation from previous progress"
    fi

    # Redirect stderr to log file so log messages don't bleed through dialog
    exec 4>&2
    exec 2>>"${LOG_FILE}"

    for entry in "${INSTALL_PHASES[@]}"; do
        local phase_name phase_desc
        IFS='|' read -r phase_name phase_desc <<< "${entry}"
        (( i++ )) || true

        if checkpoint_reached "${phase_name}"; then
            einfo "Phase ${phase_name} already completed (checkpoint)"

            # Re-mount filesystems if disks phase is skipped (needed after reboot)
            if [[ "${phase_name}" == "disks" ]]; then
                # Restore stderr temporarily for mount operations
                exec 2>&4
                mount_filesystems
                checkpoint_migrate_to_target
                _save_config_to_target
                exec 2>>"${LOG_FILE}"
            fi

            # Re-setup chroot if skipped (pseudo-FS mounts needed for later phases)
            if [[ "${phase_name}" == "xbps_preconfig" ]]; then
                chroot_setup
            fi

            continue
        fi

        if [[ "${phase_name}" == "chroot" ]]; then
            # Chroot phase — show live log output instead of static infobox
            _run_chroot_with_live_output
        else
            # Short phases — show status in dialog infobox
            _show_phase_status "${i}" "${total}" "${phase_desc}"
            _execute_phase "${phase_name}" "${phase_desc}"
        fi
    done

    # Restore stderr
    exec 2>&4
    exec 4>&-

    local complete_msg=""
    complete_msg+="Void Linux has been successfully installed!\n\n"
    complete_msg+="You can now reboot into your new system.\n"
    complete_msg+="Remember to remove the installation media.\n"

    if [[ "${ENABLE_SECUREBOOT:-no}" == "yes" ]]; then
        complete_msg+="\n--- SECURE BOOT ---\n"
        if is_secureboot_active 2>/dev/null; then
            complete_msg+="At first reboot, MokManager will appear.\n"
        else
            complete_msg+="After installation, enable Secure Boot in BIOS/UEFI.\n"
            complete_msg+="Then reboot — MokManager will appear.\n"
        fi
        complete_msg+="Select 'Enroll MOK' -> verify key -> password: void\n"
    fi

    complete_msg+="\nLog file: ${LOG_FILE}"

    dialog_msgbox "Installation Complete" "${complete_msg}"

    return "${TUI_NEXT}"
}

# _run_chroot_with_live_output — Run chroot phase with visible log output
_run_chroot_with_live_output() {
    # Restore stderr so user sees live output
    exec 2>&4

    clear 2>/dev/null || true
    echo -e "\033[1;36m══════════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;37m  Void Linux TUI Installer — Installing system                    \033[0m"
    echo -e "\033[1;36m══════════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[0;33m  Live output below. This may take a while.                       \033[0m"
    echo -e "\033[0;33m  Full log: ${LOG_FILE}                    \033[0m"
    echo -e "\033[1;36m══════════════════════════════════════════════════════════════════\033[0m"
    echo ""

    einfo "=== Phase: Chroot installation ==="

    # On --resume the xbps_preconfig phase (which mounts the ESP and copies the
    # installer into the target) may already be checkpointed and thus skipped.
    # Re-entering chroot with a stale installer copy or an unmounted ESP would
    # run old code / fail the bootloader install. Make both idempotent here so
    # the chroot phase is always entered with a fresh copy and a mounted ESP —
    # mirrors Gentoo's _execute_chroot_phase.
    if [[ -n "${ESP_PARTITION:-}" && "${DRY_RUN:-0}" != "1" ]]; then
        local esp_mount="${MOUNTPOINT}/boot/efi"
        mkdir -p "${esp_mount}"
        if ! mountpoint -q "${esp_mount}" 2>/dev/null; then
            ewarn "ESP not mounted — re-mounting ${ESP_PARTITION} at ${esp_mount}"
            try "Re-mounting ESP" mount "${ESP_PARTITION}" "${esp_mount}"
        fi
    fi
    copy_installer_to_chroot
    copy_dns_info

    export LIVE_OUTPUT=1

    chroot_setup
    run_chroot_phase
    chroot_teardown

    unset LIVE_OUTPUT

    checkpoint_set "chroot"

    echo ""
    echo -e "\033[1;32m══════════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;32m  Chroot installation complete!                                   \033[0m"
    echo -e "\033[1;32m══════════════════════════════════════════════════════════════════\033[0m"
    sleep 2

    # Re-redirect stderr for any remaining phases
    exec 2>>"${LOG_FILE}"
}

# _show_phase_status — Display current phase in dialog_infobox
_show_phase_status() {
    local current="$1" total="$2" desc="$3"

    # Build a simple text progress indicator
    local bar=""
    local j
    for (( j = 1; j <= total; j++ )); do
        if (( j < current )); then
            bar+="[done] "
        elif (( j == current )); then
            bar+="[>>>>] "
        else
            bar+="[    ] "
        fi
    done

    dialog_infobox "Installing Void Linux  [${current}/${total}]" \
        "${bar}\n\n${desc}...\n\nPlease wait. See ${LOG_FILE} for details."
}

# _execute_phase — Execute a single installation phase
_execute_phase() {
    local phase_name="$1"
    local phase_desc="$2"

    einfo "=== Phase: ${phase_desc} ==="

    maybe_exec "before_${phase_name}"

    case "${phase_name}" in
        preflight)
            preflight_checks
            ;;
        disks)
            # Resume onto a disk that already holds a Void install but lost its
            # 'disks' checkpoint: repartitioning here would wipe it. Refuse the
            # destructive plan, mount what is there, carry on.
            if [[ "${MODE:-}" == "resume" ]] && _resume_target_has_system; then
                ewarn "Resume: ${ROOT_PARTITION:-${RESUME_FOUND_PARTITION:-?}} already holds an"
                ewarn "installed Void system but the 'disks' checkpoint is missing."
                ewarn "Refusing to reformat — mounting the existing system instead."
            else
                disk_execute_plan
            fi
            mount_filesystems
            checkpoint_migrate_to_target
            _save_config_to_target
            ;;
        rootfs_download)
            rootfs_download
            ;;
        rootfs_verify)
            rootfs_verify
            ;;
        rootfs_extract)
            rootfs_extract
            ;;
        xbps_preconfig)
            xbps_configure_mirror
            xbps_configure_nonfree
            copy_dns_info
            copy_installer_to_chroot
            ;;
    esac

    maybe_exec "after_${phase_name}"

    checkpoint_set "${phase_name}"
}
