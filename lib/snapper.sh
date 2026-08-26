#!/usr/bin/env bash
# snapper.sh — Btrfs snapshots: snapper + grub-btrfs (Forgejo #8)
#
# Void packages everything needed for this to work under runit, which is the
# part that usually has to be hand-built on non-systemd distributions:
#   - snapper ships an `snapperd` runit service
#   - grub-btrfs ships a `grub-btrfs` runit service running grub-btrfsd, an
#     inotify watcher on /.snapshots that regenerates the GRUB menu whenever a
#     snapshot appears (the equivalent of the systemd path unit upstream uses)
#   - cronie provides run-parts over /etc/cron.{hourly,daily}, which is how the
#     timeline and cleanup jobs get scheduled without systemd timers
#
# What Void does NOT have is snap-pac (a pacman hook): XBPS has no
# pre/post-transaction hooks at all, so an automatic snapshot before an update
# is provided as an explicit wrapper command instead of pretending it is
# automatic.
source "${LIB_DIR}/protection.sh"

# snapper_setup — Entry point for the chroot phase.
snapper_setup() {
    [[ "${ENABLE_SNAPPER:-no}" == "yes" ]] || return 0

    if [[ "${FILESYSTEM:-}" != "btrfs" ]]; then
        ewarn "Snapshots require btrfs — skipping snapper setup"
        return 0
    fi

    einfo "Setting up btrfs snapshots (snapper + grub-btrfs)..."

    try "Installing snapper and grub-btrfs" xbps-install -y snapper grub-btrfs cronie

    _snapper_create_root_config
    _snapper_write_cron_jobs
    _snapper_enable_services
    _snapper_install_update_wrapper
    _snapper_write_note

    einfo "Snapshot support configured"
}

# _snapper_create_root_config — Create the `root` config on a layout that
# already has a @snapshots subvolume mounted at /.snapshots.
#
# `snapper create-config` insists on creating its own .snapshots subvolume and
# fails if the path is already a mount point. The dance below is the standard
# workaround: unmount ours, let snapper do its thing, throw away the subvolume
# it made, and put ours back. Without it the config either fails to create or
# snapshots land on a subvolume that is not the one fstab mounts.
_snapper_create_root_config() {
    if [[ -f /etc/snapper/configs/root ]]; then
        einfo "  snapper config 'root' already exists — leaving it alone"
        return 0
    fi

    local remount=0
    if mountpoint -q /.snapshots 2>/dev/null; then
        umount /.snapshots && remount=1
    fi
    rm -rf /.snapshots 2>/dev/null || true

    if ! snapper --no-dbus -c root create-config / 2>/dev/null; then
        ewarn "  snapper create-config failed — snapshots not configured"
        [[ ${remount} -eq 1 ]] && { mkdir -p /.snapshots; mount /.snapshots 2>/dev/null || true; }
        return 1
    fi

    # snapper just created its own .snapshots subvolume; ours (@snapshots) is
    # the one fstab knows about, so drop snapper's and restore the mount.
    btrfs subvolume delete /.snapshots 2>/dev/null || rm -rf /.snapshots 2>/dev/null || true
    mkdir -p /.snapshots
    if [[ ${remount} -eq 1 ]]; then
        mount /.snapshots 2>/dev/null || ewarn "  Could not remount /.snapshots"
    fi
    chmod 750 /.snapshots 2>/dev/null || true

    _snapper_tune_config
    einfo "  snapper config 'root' created"
}

# _snapper_tune_config — Sane retention for a rolling-release desktop.
# Defaults keep 10 hourly + 10 daily + 10 weekly + 10 monthly + 10 yearly,
# which fills a small SSD faster than anyone expects.
_snapper_tune_config() {
    local cfg=/etc/snapper/configs/root
    [[ -f "${cfg}" ]] || return 0

    _snapper_set_option "${cfg}" "ALLOW_GROUPS" "wheel"
    _snapper_set_option "${cfg}" "TIMELINE_CREATE" "yes"
    _snapper_set_option "${cfg}" "TIMELINE_CLEANUP" "yes"
    _snapper_set_option "${cfg}" "TIMELINE_LIMIT_HOURLY" "5"
    _snapper_set_option "${cfg}" "TIMELINE_LIMIT_DAILY" "7"
    _snapper_set_option "${cfg}" "TIMELINE_LIMIT_WEEKLY" "2"
    _snapper_set_option "${cfg}" "TIMELINE_LIMIT_MONTHLY" "1"
    _snapper_set_option "${cfg}" "TIMELINE_LIMIT_YEARLY" "0"
    # Snapshots taken around updates: keep a useful window, not forever
    _snapper_set_option "${cfg}" "NUMBER_CLEANUP" "yes"
    _snapper_set_option "${cfg}" "NUMBER_LIMIT" "10"
    _snapper_set_option "${cfg}" "NUMBER_LIMIT_IMPORTANT" "5"
}

# _snapper_set_option — Replace KEY="value" in a snapper config file.
# The value is quoted and the key anchored, so a partial name (NUMBER_LIMIT vs
# NUMBER_LIMIT_IMPORTANT) cannot match the wrong line.
_snapper_set_option() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "${file}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
    else
        printf '%s="%s"\n' "${key}" "${value}" >> "${file}"
    fi
}

# _snapper_write_cron_jobs — Timeline and cleanup without systemd timers.
# cronie runs run-parts over these directories; upstream snapper schedules the
# same two commands from systemd timers.
_snapper_write_cron_jobs() {
    mkdir -p /etc/cron.hourly /etc/cron.daily

    cat > /etc/cron.hourly/snapper-timeline << 'EOF'
#!/bin/sh
# Hourly timeline snapshot — installed by the Void installer
exec /usr/bin/snapper --no-dbus timeline
EOF
    chmod 755 /etc/cron.hourly/snapper-timeline

    cat > /etc/cron.daily/snapper-cleanup << 'EOF'
#!/bin/sh
# Daily snapshot cleanup — installed by the Void installer
/usr/bin/snapper --no-dbus cleanup timeline
/usr/bin/snapper --no-dbus cleanup number
EOF
    chmod 755 /etc/cron.daily/snapper-cleanup

    einfo "  Timeline and cleanup scheduled via cron"
}

# _snapper_enable_services — snapperd (D-Bus API), grub-btrfsd (menu watcher),
# cronie (the scheduler the two jobs above depend on).
_snapper_enable_services() {
    _enable_service "snapperd"
    _enable_service "cronie"

    # grub-btrfsd watches /.snapshots via inotify and regenerates grub.cfg, so
    # a new snapshot shows up in the boot menu without any manual step.
    _enable_service "grub-btrfs"
}

# _snapper_install_update_wrapper — XBPS has no transaction hooks, so the
# "snapshot before an update" behaviour that snap-pac gives Arch users is
# provided as a command they run instead of xbps-install.
_snapper_install_update_wrapper() {
    local wrapper=/usr/local/bin/xbps-snapshot
    mkdir -p /usr/local/bin

    cat > "${wrapper}" << 'EOF'
#!/bin/sh
# xbps-snapshot — run an XBPS transaction between two snapper snapshots.
#
# XBPS has no pre/post-transaction hooks (unlike pacman + snap-pac), so this
# wrapper is the explicit equivalent. Use it exactly as you would xbps-install:
#
#   xbps-snapshot -Su                 # snapshot, full update, snapshot
#   xbps-snapshot -y some-package     # snapshot, install, snapshot
#
# Roll back from the GRUB menu ("Void Linux snapshots" submenu), or with
# `snapper rollback <number>` from a running system.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "xbps-snapshot: must run as root" >&2
    exit 1
fi

DESC="xbps $*"

PRE=$(snapper --no-dbus create --type pre --cleanup-algorithm number \
        --print-number --description "${DESC}") || {
    echo "xbps-snapshot: pre-snapshot failed, aborting" >&2
    exit 1
}
echo "xbps-snapshot: pre-snapshot #${PRE}"

if xbps-install "$@"; then
    STATUS=0
else
    STATUS=$?
    echo "xbps-snapshot: transaction failed (exit ${STATUS})" >&2
fi

POST=$(snapper --no-dbus create --type post --pre-number "${PRE}" \
        --cleanup-algorithm number --print-number --description "${DESC}") || true
[ -n "${POST}" ] && echo "xbps-snapshot: post-snapshot #${POST}"

exit "${STATUS}"
EOF
    chmod 755 "${wrapper}"

    einfo "  Update wrapper installed: xbps-snapshot"
}

# _snapper_write_note — What the user has to know to actually use this.
_snapper_write_note() {
    cat > /root/POST-INSTALL-SNAPSHOTS.txt << 'EOF'
Btrfs snapshots (snapper + grub-btrfs)
======================================

Automatic
---------
  - hourly timeline snapshot      (/etc/cron.hourly/snapper-timeline)
  - daily cleanup                 (/etc/cron.daily/snapper-cleanup)
  - GRUB menu updated on its own   (grub-btrfsd watches /.snapshots)

Retention: 5 hourly, 7 daily, 2 weekly, 1 monthly. Tune in
/etc/snapper/configs/root.

Before an update
----------------
XBPS has no transaction hooks (there is no snap-pac for Void), so use the
wrapper instead of xbps-install when you want a snapshot pair around a change:

  xbps-snapshot -Su

Everyday commands
-----------------
  snapper list                    # what exists
  snapper create -d "before X"    # manual snapshot
  snapper status 41..42           # what changed between two
  snapper undochange 41..42       # revert those file changes
  snapper rollback 41             # make 41 the new root (reboot after)

Rolling back from the boot menu
-------------------------------
GRUB has a "Void Linux snapshots" submenu. Booting a snapshot mounts it
read-only; to keep it, run `snapper rollback` once the system is up.

Members of the wheel group can use snapper without sudo (ALLOW_GROUPS).
EOF

    einfo "  Notes written to /root/POST-INSTALL-SNAPSHOTS.txt"
}
