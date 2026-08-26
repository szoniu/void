#!/usr/bin/env bash
# tui/filesystem_select.sh — Filesystem selection: ext4 / btrfs / XFS
source "${LIB_DIR}/protection.sh"

screen_filesystem_select() {
    # In manual mode, detect filesystem from already-formatted partition
    if [[ "${PARTITION_SCHEME:-}" == "manual" && -n "${ROOT_PARTITION:-}" ]]; then
        local detected_fs
        detected_fs=$(blkid -o value -s TYPE "${ROOT_PARTITION}" 2>/dev/null) || true
        if [[ -n "${detected_fs}" ]]; then
            FILESYSTEM="${detected_fs}"
            export FILESYSTEM
            einfo "Detected filesystem on ${ROOT_PARTITION}: ${FILESYSTEM}"

            # For btrfs, ask about subvolumes even in manual mode
            if [[ "${FILESYSTEM}" == "btrfs" ]]; then
                BTRFS_SUBVOLUMES="@:/:@home:/home:@var-log:/var/log:@snapshots:/.snapshots"

                dialog_yesno "Btrfs Subvolumes" \
                    "Detected btrfs on ${ROOT_PARTITION}.\n\n\
Create default subvolumes?\n\n\
  @           -> /\n\
  @home       -> /home\n\
  @var-log    -> /var/log\n\
  @snapshots  -> /.snapshots\n\n\
Select No to skip subvolume creation." && {
                    export BTRFS_SUBVOLUMES
                } || {
                    BTRFS_SUBVOLUMES=""
                    export BTRFS_SUBVOLUMES
                }
            fi

            return "${TUI_NEXT}"
        fi
    fi

    local current="${FILESYSTEM:-ext4}"
    local on_ext4="off" on_btrfs="off" on_xfs="off"
    case "${current}" in
        ext4)  on_ext4="on" ;;
        btrfs) on_btrfs="on" ;;
        xfs)   on_xfs="on" ;;
    esac

    local choice
    choice=$(dialog_radiolist "Root Filesystem" \
        "ext4"  "ext4 — stable, proven, recommended for beginners" "${on_ext4}" \
        "btrfs" "btrfs — snapshots, subvolumes, compression" "${on_btrfs}" \
        "xfs"   "XFS — high performance, good for large files" "${on_xfs}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    FILESYSTEM="${choice}"
    export FILESYSTEM

    # Btrfs subvolumes configuration
    if [[ "${FILESYSTEM}" == "btrfs" ]]; then
        BTRFS_SUBVOLUMES="@:/:@home:/home:@var-log:/var/log:@snapshots:/.snapshots"

        dialog_yesno "Btrfs Subvolumes" \
            "The following btrfs subvolumes will be created:\n\n\
  @           -> /\n\
  @home       -> /home\n\
  @var-log    -> /var/log\n\
  @snapshots  -> /.snapshots\n\n\
Use these defaults?" || {
            local custom
            custom=$(dialog_inputbox "Custom Subvolumes" \
                "Enter subvolumes (format: name:mountpoint pairs, colon-separated):\n\
Example: @:/:@home:/home:@var-log:/var/log" \
                "${BTRFS_SUBVOLUMES}") || return "${TUI_BACK}"
            BTRFS_SUBVOLUMES="${custom}"
        }

        export BTRFS_SUBVOLUMES
    else
        BTRFS_SUBVOLUMES=""
        export BTRFS_SUBVOLUMES
    fi

    _screen_snapshots_prompt
    _screen_luks_prompt || return "${TUI_BACK}"

    einfo "Filesystem: ${FILESYSTEM}, LUKS: ${LUKS_ENABLED:-no}"
    return "${TUI_NEXT}"
}

# _screen_snapshots_prompt — Offer snapper + grub-btrfs on btrfs layouts.
#
# Requires a @snapshots subvolume: snapper stores snapshots under /.snapshots,
# and without a dedicated subvolume there they would end up inside @ — which
# means every snapshot would contain the previous ones, and a rollback could
# not work.
_screen_snapshots_prompt() {
    if [[ "${FILESYSTEM:-}" != "btrfs" ]]; then
        ENABLE_SNAPPER="no"
        export ENABLE_SNAPPER
        return 0
    fi

    if [[ "${BTRFS_SUBVOLUMES:-}" != *"@snapshots"* ]]; then
        ENABLE_SNAPPER="no"
        export ENABLE_SNAPPER
        einfo "No @snapshots subvolume in the layout — snapshots not offered"
        return 0
    fi

    if dialog_yesno "Btrfs Snapshots" \
        "Set up automatic snapshots (snapper + grub-btrfs)?\n\n\
  - hourly timeline snapshot, daily cleanup (via cron)\n\
  - snapshots appear in the GRUB menu automatically\n\
  - 'xbps-snapshot -Su' wraps an update in two snapshots\n\n\
Useful on a rolling release: a bad update is one reboot\n\
away from being undone. Costs disk space — retention is\n\
5 hourly / 7 daily / 2 weekly / 1 monthly by default."; then
        ENABLE_SNAPPER="yes"
    else
        ENABLE_SNAPPER="no"
    fi
    export ENABLE_SNAPPER

    return 0
}

# _screen_luks_prompt — Offer full-disk encryption for the root partition.
#
# Only offered for schemes where the installer creates the root filesystem:
# in manual mode the partition already exists (and may already be a container
# the user set up themselves), so the installer does not touch it.
_screen_luks_prompt() {
    if [[ "${PARTITION_SCHEME:-}" == "manual" ]]; then
        LUKS_ENABLED="${LUKS_ENABLED:-no}"
        export LUKS_ENABLED
        return 0
    fi

    # Void's live ISO ships cryptsetup in every flavour, but the installer
    # also runs from other live media.
    if [[ "${DRY_RUN:-0}" != "1" ]] && ! command -v cryptsetup >/dev/null 2>&1; then
        LUKS_ENABLED="no"
        export LUKS_ENABLED
        einfo "cryptsetup not available on this live medium — encryption not offered"
        return 0
    fi

    local warn=""
    if [[ "${APPLE_SPI_INPUT:-0}" == "1" ]]; then
        # The passphrase prompt runs from the initramfs, before the desktop
        # exists — on these Macs that only works because the SPI keyboard
        # modules are forced into the initramfs (lib/apple.sh).
        warn="\n\nThis Mac's keyboard is on SPI; the installer puts its\ndrivers in the initramfs so you can type the passphrase\nat boot. An external USB keyboard is a good backup.\n"
    fi

    if dialog_yesno "Disk Encryption (LUKS)" \
        "Encrypt the root partition with LUKS?\n\n\
Everything except the EFI partition is encrypted. You type\n\
a passphrase at every boot, before the system starts.\n\n\
There is NO recovery if the passphrase is lost.${warn}"; then
        LUKS_ENABLED="yes"
        export LUKS_ENABLED

        if ! luks_prompt_passphrase; then
            LUKS_ENABLED="no"
            export LUKS_ENABLED
            return 1
        fi
    else
        LUKS_ENABLED="no"
        export LUKS_ENABLED
    fi

    return 0
}
