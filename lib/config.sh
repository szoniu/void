#!/usr/bin/env bash
# config.sh — Save/load configuration using ${VAR@Q} quoting
source "${LIB_DIR}/protection.sh"

# config_save — Serialize all CONFIG_VARS to a sourceable bash file
config_save() {
    local file="${1:-${CONFIG_FILE}}"
    local dir
    dir="$(dirname "${file}")"
    mkdir -p "${dir}"

    # Restrict permissions — file contains password hashes
    (
        umask 077
        {
            echo "#!/usr/bin/env bash"
            echo "# Void TUI Installer configuration"
            echo "# Generated: $(date -Iseconds)"
            echo "# Version: ${INSTALLER_VERSION}"
            echo ""

            local var
            for var in "${CONFIG_VARS[@]}"; do
                if [[ -n "${!var+x}" ]]; then
                    # Use ${VAR@Q} for safe quoting
                    echo "${var}=${!var@Q}"
                fi
            done
        } > "${file}"
    )

    einfo "Configuration saved to ${file}"
}

# config_load — Load configuration from file
config_load() {
    local file="${1:-${CONFIG_FILE}}"

    if [[ ! -f "${file}" ]]; then
        eerror "Configuration file not found: ${file}"
        return 1
    fi

    # Build a filtered file with only known CONFIG_VARS assignments
    local safe_file
    safe_file=$(mktemp "${TMPDIR:-/tmp}/void-config-safe.XXXXXX")

    local line_num=0
    while IFS= read -r line; do
        (( line_num++ )) || true
        # Pass through comments and empty lines
        if [[ "${line}" =~ ^[[:space:]]*# ]] || [[ "${line}" =~ ^[[:space:]]*$ ]] || [[ "${line}" =~ ^#! ]]; then
            echo "${line}" >> "${safe_file}"
            continue
        fi

        # Must be a known variable assignment
        local var_name
        var_name="${line%%=*}"
        var_name="${var_name%%[[:space:]]*}"

        local found=0
        local known_var
        for known_var in "${CONFIG_VARS[@]}"; do
            if [[ "${var_name}" == "${known_var}" ]]; then
                found=1
                break
            fi
        done

        if [[ ${found} -eq 0 ]]; then
            ewarn "Unknown variable at line ${line_num}: ${var_name} (skipping)"
            continue
        fi
        echo "${line}" >> "${safe_file}"
    done < "${file}"

    # Source the filtered file (only known variables)
    # shellcheck disable=SC1090
    source "${safe_file}"
    rm -f "${safe_file}"

    einfo "Configuration loaded from ${file}"
}

# config_get — Get a config variable value (for external scripts)
config_get() {
    local var="$1"
    echo "${!var:-}"
}

# config_set — Set a config variable
config_set() {
    local var="$1" value="$2"

    # Validate variable name is in CONFIG_VARS
    local found=0
    local known_var
    for known_var in "${CONFIG_VARS[@]}"; do
        if [[ "${var}" == "${known_var}" ]]; then
            found=1
            break
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        ewarn "Setting unknown config variable: ${var}"
    fi

    printf -v "${var}" '%s' "${value}"
    # Intentional indirect export of the variable *named* by ${var}.
    # shellcheck disable=SC2163
    export "${var}"
}

# config_dump — Print current configuration to stdout
config_dump() {
    local var
    for var in "${CONFIG_VARS[@]}"; do
        if [[ -n "${!var+x}" ]]; then
            echo "${var}=${!var@Q}"
        fi
    done
}

# config_diff — Compare two config files, showing differences
config_diff() {
    local file1="$1" file2="$2"
    diff --unified=0 \
        <(sort "${file1}" | grep -v '^#' | grep -v '^$') \
        <(sort "${file2}" | grep -v '^#' | grep -v '^$') || true
}

# validate_config — Check configuration consistency before installation
# Prints error messages to stdout. Returns 0 if valid, 1 if errors found.
#
# _validate_phase_pending — is the phase that consumes a field still ahead?
#
# In "full" mode every phase is ahead by definition. In "resume" mode the
# answer comes from the checkpoints, which _recover_resume_data() has already
# copied into CHECKPOINT_DIR by the time the gate runs (lib/utils.sh) — so a
# field whose phase is done is not demanded. Unknown state answers "pending",
# which is the strict side.
_validate_phase_pending() {
    local mode="$1" phase="$2"
    [[ "${mode}" != "resume" ]] && return 0
    declare -F checkpoint_reached >/dev/null || return 0
    checkpoint_reached "${phase}" && return 1
    return 0
}

# $1 — validation mode:
#   full   (default) every field the wizard collects must be present. Used by
#          the summary screen and by --install, where the config file is
#          expected to be complete.
#   resume a field is demanded only while the phase that consumes it is still
#          ahead. An inferred --resume config cannot recover USERNAME or the
#          password hashes (nothing readable stores them) and never sets
#          GPU_VENDOR at all — there is no _infer_* for it, because the value
#          comes from detect_gpu(), which only the wizard runs. Demanding those
#          would turn every inferred resume into a full wizard run, i.e. break
#          the recovery path this gate exists to protect. Keying on the
#          checkpoint rather than on "MODE=resume" also closes the opposite
#          hole: a resume that crashed BEFORE the users phase still has to
#          carry account fields, or it would install a system nobody can log
#          into. Every other check applies in both modes: enums, formats,
#          block devices and cross-field consistency are what actually stand
#          between a hand-edited value and a destructive phase.
validate_config() {
    local mode="${1:-full}"
    local -a errors=()

    # --- Required variables (must be non-empty) ---
    # NOTE: HOSTNAME is also a variable bash sets itself, so its emptiness
    # check can never fire. Left in place deliberately — removing it would
    # imply the field is optional; the real bug is that _infer_from_hostname()
    # bails on the same shell variable and never reads the target's
    # /etc/hostname. Tracked separately.
    local -a required=(TARGET_DISK FILESYSTEM)
    _validate_phase_pending "${mode}" "system_config" && required+=(HOSTNAME TIMEZONE LOCALE)
    _validate_phase_pending "${mode}" "kernel"        && required+=(KERNEL_TYPE)
    _validate_phase_pending "${mode}" "desktop"       && required+=(GPU_VENDOR)
    _validate_phase_pending "${mode}" "users"         && required+=(USERNAME ROOT_PASSWORD_HASH USER_PASSWORD_HASH)
    local var
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            errors+=("${var} is required but not set")
        fi
    done

    # --- Enum validation (only check if non-empty) ---
    if [[ -n "${PARTITION_SCHEME:-}" ]] && \
       [[ "${PARTITION_SCHEME}" != "auto" && "${PARTITION_SCHEME}" != "dual-boot" && "${PARTITION_SCHEME}" != "manual" ]]; then
        errors+=("PARTITION_SCHEME='${PARTITION_SCHEME}' — must be auto, dual-boot, or manual")
    fi

    if [[ -n "${FILESYSTEM:-}" ]] && \
       [[ "${FILESYSTEM}" != "ext4" && "${FILESYSTEM}" != "btrfs" && "${FILESYSTEM}" != "xfs" ]]; then
        errors+=("FILESYSTEM='${FILESYSTEM}' — must be ext4, btrfs, or xfs")
    fi

    if [[ -n "${SWAP_TYPE:-}" ]] && \
       [[ "${SWAP_TYPE}" != "zram" && "${SWAP_TYPE}" != "partition" && "${SWAP_TYPE}" != "file" && "${SWAP_TYPE}" != "none" ]]; then
        errors+=("SWAP_TYPE='${SWAP_TYPE}' — must be zram, partition, file, or none")
    fi

    if [[ -n "${KERNEL_TYPE:-}" ]] && \
       [[ "${KERNEL_TYPE}" != "mainline" && "${KERNEL_TYPE}" != "lts" && "${KERNEL_TYPE}" != "surface-patched" ]]; then
        errors+=("KERNEL_TYPE='${KERNEL_TYPE}' — must be mainline, lts, or surface-patched")
    fi

    if [[ "${ENABLE_SECUREBOOT:-no}" == "yes" && -z "${ESP_PARTITION:-}" ]]; then
        errors+=("ENABLE_SECUREBOOT=yes requires ESP_PARTITION to be set")
    fi

    if [[ "${ENABLE_SNAPPER:-no}" != "no" && "${ENABLE_SNAPPER:-no}" != "yes" ]]; then
        errors+=("ENABLE_SNAPPER='${ENABLE_SNAPPER}' — must be yes or no")
    fi

    if [[ "${ENABLE_SNAPPER:-no}" == "yes" && "${FILESYSTEM:-}" != "btrfs" ]]; then
        errors+=("ENABLE_SNAPPER=yes requires FILESYSTEM=btrfs (got '${FILESYSTEM:-unset}')")
    fi

    if [[ "${WAYLAND_ONLY:-no}" != "no" && "${WAYLAND_ONLY:-no}" != "yes" ]]; then
        errors+=("WAYLAND_ONLY='${WAYLAND_ONLY}' — must be yes or no")
    fi

    if [[ "${LUKS_ENABLED:-no}" != "no" && "${LUKS_ENABLED:-no}" != "yes" ]]; then
        errors+=("LUKS_ENABLED='${LUKS_ENABLED}' — must be yes or no")
    fi

    if [[ "${LUKS_ALLOW_DISCARDS:-no}" != "no" && "${LUKS_ALLOW_DISCARDS:-no}" != "yes" ]]; then
        errors+=("LUKS_ALLOW_DISCARDS='${LUKS_ALLOW_DISCARDS}' — must be yes or no")
    fi

    # A stale yes from a preset would otherwise sit in the config claiming a
    # security trade-off that nothing acts on — the option only has meaning
    # for a container this installer opens.
    if [[ "${LUKS_ALLOW_DISCARDS:-no}" == "yes" && "${LUKS_ENABLED:-no}" != "yes" ]]; then
        errors+=("LUKS_ALLOW_DISCARDS=yes requires LUKS_ENABLED=yes")
    fi

    if [[ "${LUKS_ENABLED:-no}" == "yes" ]]; then
        # ROOT_PARTITION is the mapper device once LUKS is planned; the raw
        # partition must still be recorded, otherwise crypttab and the GRUB
        # cmdline have no UUID to point at.
        #
        # But it is disk_plan_auto/disk_plan_dualboot that assign it, and those
        # run from disk_execute_plan — i.e. AFTER this gate on every path,
        # including the summary screen. Demanding it unconditionally rejected
        # every fresh LUKS install at the summary, with no way forward but
        # editing the config by hand. So the check keys on the state that
        # proves the plan already ran: ROOT_PARTITION pointing at a mapper
        # node. Then an empty LUKS_PARTITION is a real defect.
        if [[ -z "${LUKS_PARTITION:-}" ]] && [[ "${PARTITION_SCHEME:-}" != "manual" ]] && \
           [[ "${ROOT_PARTITION:-}" == /dev/mapper/* ]]; then
            errors+=("LUKS_ENABLED=yes and root is ${ROOT_PARTITION}, but LUKS_PARTITION is empty")
        fi
        if [[ "${PARTITION_SCHEME:-}" == "manual" ]]; then
            errors+=("LUKS is not supported with manual partitioning — set up the container yourself and choose 'no'")
        fi
    fi

    if [[ -n "${DESKTOP_TYPE:-}" ]] && \
       [[ "${DESKTOP_TYPE}" != "kde" && "${DESKTOP_TYPE}" != "gnome" ]]; then
        errors+=("DESKTOP_TYPE='${DESKTOP_TYPE}' — must be kde or gnome")
    fi

    if [[ -n "${GPU_VENDOR:-}" ]] && \
       [[ "${GPU_VENDOR}" != "nvidia" && "${GPU_VENDOR}" != "amd" && "${GPU_VENDOR}" != "intel" && "${GPU_VENDOR}" != "none" && "${GPU_VENDOR}" != "unknown" ]]; then
        errors+=("GPU_VENDOR='${GPU_VENDOR}' — must be nvidia, amd, intel, none, or unknown")
    fi

    if [[ -n "${NOCTALIA_COMPOSITOR:-}" ]] && \
       [[ "${NOCTALIA_COMPOSITOR}" != "Hyprland" && "${NOCTALIA_COMPOSITOR}" != "niri" && "${NOCTALIA_COMPOSITOR}" != "sway" ]]; then
        errors+=("NOCTALIA_COMPOSITOR='${NOCTALIA_COMPOSITOR}' — must be Hyprland, niri, or sway")
    fi

    # --- Format validation ---
    # Hostname: RFC 1123
    if [[ -n "${HOSTNAME:-}" ]] && \
       [[ ! "${HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        errors+=("HOSTNAME='${HOSTNAME}' — invalid (RFC 1123: alphanumeric + hyphens, 1-63 chars)")
    fi

    # Locale: xx_XX.UTF-8
    # A console font name is used as a GLOB (compgen -G) and as a sed replacement
    # in system_set_console_font. Catching it here means a bad value from a
    # hand-edited preset or an inferred --resume config fails the pre-flight gate
    # instead of silently doing nothing halfway through the chroot.
    if [[ -n "${CONSOLE_FONT:-}" ]] && \
       [[ ! "${CONSOLE_FONT}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        errors+=("CONSOLE_FONT='${CONSOLE_FONT}' — only letters, digits, dot, underscore and hyphen")
    fi

    if [[ -n "${LOCALE:-}" ]] && \
       [[ ! "${LOCALE}" =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
        errors+=("LOCALE='${LOCALE}' — must match xx_XX.UTF-8 format")
    fi

    # Mirror must be https:// — the ROOTFS is authenticated only by a checksum
    # file fetched from the same mirror, so plain http is a MITM hole. http://
    # is auto-upgraded by void_mirror() at runtime; any other scheme is fatal.
    if [[ -n "${MIRROR_URL:-}" ]] && \
       [[ ! "${MIRROR_URL}" =~ ^https?:// ]]; then
        errors+=("MIRROR_URL='${MIRROR_URL}' — must be an http(s):// URL (https strongly preferred)")
    fi

    # --- Block device checks (skip in DRY_RUN) ---
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if [[ -n "${TARGET_DISK:-}" && "${PARTITION_SCHEME:-auto}" != "manual" ]] && \
           [[ ! -b "${TARGET_DISK}" ]]; then
            errors+=("TARGET_DISK='${TARGET_DISK}' — block device does not exist")
        fi

        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" && "${ESP_REUSE:-no}" == "yes" ]] && \
           [[ -n "${ESP_PARTITION:-}" && ! -b "${ESP_PARTITION}" ]]; then
            errors+=("ESP_PARTITION='${ESP_PARTITION}' — block device does not exist")
        fi

        # An encrypted root is /dev/mapper/<name>, and that node does not
        # exist until screen_progress opens the container — which happens
        # AFTER this gate, on purpose (unlocking prompts for a passphrase and
        # touches the disk; validation comes first). So a missing mapper node
        # is not a configuration error here. The raw partition underneath is,
        # and it exists regardless of the container's state — so a typo in a
        # hand-edited preset is still caught, just on the field that can
        # actually be checked at this point.
        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" ]]; then
            if [[ "${LUKS_ENABLED:-no}" == "yes" && "${ROOT_PARTITION:-}" == /dev/mapper/* ]]; then
                if [[ -n "${LUKS_PARTITION:-}" && ! -b "${LUKS_PARTITION}" ]]; then
                    errors+=("LUKS_PARTITION='${LUKS_PARTITION}' — block device does not exist")
                fi
            elif [[ -n "${ROOT_PARTITION:-}" && ! -b "${ROOT_PARTITION}" ]]; then
                errors+=("ROOT_PARTITION='${ROOT_PARTITION}' — block device does not exist")
            fi
        fi
    fi

    # --- Cross-field logic ---
    if [[ "${SWAP_TYPE:-}" == "file" ]] && \
       [[ -z "${SWAP_SIZE_MIB:-}" || "${SWAP_SIZE_MIB:-0}" -le 0 ]]; then
        errors+=("SWAP_TYPE=file requires SWAP_SIZE_MIB > 0")
    fi

    if [[ "${PARTITION_SCHEME:-}" == "dual-boot" ]] && \
       [[ -z "${ESP_PARTITION:-}" ]]; then
        errors+=("PARTITION_SCHEME=dual-boot requires ESP_PARTITION to be set")
    fi

    if [[ -n "${SHRINK_PARTITION:-}" ]]; then
        if [[ -n "${SHRINK_PARTITION_FSTYPE:-}" ]] && \
           [[ "${SHRINK_PARTITION_FSTYPE}" != "ntfs" && "${SHRINK_PARTITION_FSTYPE}" != "ext4" && "${SHRINK_PARTITION_FSTYPE}" != "btrfs" ]]; then
            errors+=("SHRINK_PARTITION_FSTYPE='${SHRINK_PARTITION_FSTYPE}' — must be ntfs, ext4, or btrfs")
        fi
        if [[ -z "${SHRINK_NEW_SIZE_MIB:-}" || "${SHRINK_NEW_SIZE_MIB:-0}" -le 0 ]]; then
            errors+=("SHRINK_PARTITION set requires SHRINK_NEW_SIZE_MIB > 0")
        fi
    fi

    # --- Output ---
    if [[ ${#errors[@]} -gt 0 ]]; then
        local err
        for err in "${errors[@]}"; do
            echo "- ${err}"
        done
        return 1
    fi

    return 0
}

# validate_config_gate — Pre-flight validation for entry points that skip the
# summary screen.
#
# validate_config() used to have exactly ONE production caller (tui/summary.sh),
# so `--install` (config file straight to screen_progress) and the inferred
# `--resume` path ran with NO gate at all: a hand-edited preset or a value
# recovered from a half-installed system went to the destructive phases with its
# enums, block devices and cross-field consistency unchecked (Forgejo #27).
#
# Called from screen_progress() before anything touches the disk. On the wizard
# path this repeats the summary screen's check, which is free and keeps the gate
# in one place rather than three.
#
# Failure handling differs by context on purpose:
#   - non-interactive: die, because there is nobody to fix the config and the
#     next step formats a disk.
#   - interactive: show the errors and offer the wizard, which is the friendlier
#     answer on --resume after a crash — the alternative is telling someone
#     mid-recovery to go hand-edit a file.
validate_config_gate() {
    local mode="full"
    [[ "${MODE:-}" == "resume" ]] && mode="resume"

    # GPU_VENDOR has no _infer_* counterpart — the value comes from
    # detect_gpu(), which only the wizard runs (via tui/hw_detect.sh). An
    # inferred --resume config therefore arrives without it, and the desktop
    # phase genuinely needs it. Re-detecting is the right answer rather than
    # the strict one: it is the same machine as the first attempt, and
    # detect_gpu only reads lspci/sysfs — it touches nothing.
    if [[ "${mode}" == "resume" && -z "${GPU_VENDOR:-}" ]] && \
       declare -F detect_gpu >/dev/null; then
        detect_gpu || true
    fi

    local errors
    errors=$(validate_config "${mode}") && return 0

    eerror "Configuration validation failed:"
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && eerror "  ${line}"
    done <<< "${errors}"

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]] || ! declare -F dialog_yesno >/dev/null; then
        die "Refusing to start the installation with an invalid configuration"
    fi

    # dialog/whiptail collapse embedded newlines when wrapping (that is what
    # --cr-wrap exists for), so a multi-line error list would arrive as one
    # run-on paragraph. The rest of the repo builds dialog text with literal
    # \n sequences, which dialog does expand — so match that.
    dialog_msgbox "Configuration Errors" \
        "The configuration cannot be installed as it stands:\n\n${errors//$'\n'/\\n}"

    if ! declare -F run_configuration_wizard >/dev/null; then
        die "Refusing to start the installation with an invalid configuration"
    fi

    if ! dialog_yesno "Fix Configuration" \
        "Open the configuration wizard to correct this?\n\nChoosing 'No' aborts the installation."; then
        die "Aborted — configuration was not corrected"
    fi

    run_configuration_wizard

    # The wizard's own summary screen validates in "full" mode, but it can be
    # left by other routes; re-check rather than trust that it was reached.
    errors=$(validate_config "${mode}") && return 0

    die "Configuration is still invalid after the wizard:"$'\n'"${errors}"
}
