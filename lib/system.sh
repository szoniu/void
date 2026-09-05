#!/usr/bin/env bash
# system.sh — System configuration for Void Linux
source "${LIB_DIR}/protection.sh"

# system_set_timezone — Configure timezone
system_set_timezone() {
    local tz="${TIMEZONE:-UTC}"

    # Validate timezone
    if [[ ! -f "/usr/share/zoneinfo/${tz}" ]]; then
        ewarn "Invalid timezone '${tz}', falling back to UTC"
        tz="UTC"
    fi

    einfo "Setting timezone: ${tz}"

    # Void uses /etc/localtime symlink
    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime

    # Also write to /etc/timezone for reference
    echo "${tz}" > /etc/timezone

    einfo "Timezone set to ${tz}"
}

# system_set_locale — Configure locale
system_set_locale() {
    local locale="${LOCALE:-en_US.UTF-8}"
    einfo "Setting locale: ${locale}"

    # Enable locale in libc-locales
    local locales_file="/etc/default/libc-locales"
    if [[ -f "${locales_file}" ]]; then
        # Uncomment the desired locale. Escape regex metacharacters in the
        # locale (notably the '.' in 'en_US.UTF-8', which would otherwise match
        # any char and could uncomment the wrong line).
        local locale_re="${locale//\\/\\\\}"
        locale_re="${locale_re//./\\.}"
        sed -i "s/^#[[:space:]]*\(${locale_re}\)/\1/" "${locales_file}"
        # Also enable en_US.UTF-8 as fallback if not already the primary
        if [[ "${locale}" != "en_US.UTF-8" ]]; then
            sed -i 's/^#\(en_US\.UTF-8\)/\1/' "${locales_file}"
        fi
    else
        mkdir -p "$(dirname "${locales_file}")"
        echo "${locale} UTF-8" > "${locales_file}"
        echo "en_US.UTF-8 UTF-8" >> "${locales_file}"
    fi

    # Set system locale
    echo "LANG=${locale}" > /etc/locale.conf

    # Reconfigure glibc-locales to generate locales (skip on musl)
    if xbps-query glibc-locales &>/dev/null; then
        try "Generating locales" xbps-reconfigure -f glibc-locales
    fi

    einfo "Locale set to ${locale}"
}

# system_set_hostname — Configure hostname
system_set_hostname() {
    local hostname="${HOSTNAME:-void}"

    # Validate hostname (RFC 1123: alphanumeric + hyphens, no leading/trailing hyphen)
    if [[ ! "${hostname}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        ewarn "Invalid hostname '${hostname}', falling back to 'void'"
        hostname="void"
    fi

    einfo "Setting hostname: ${hostname}"

    echo "${hostname}" > /etc/hostname

    # Update /etc/hosts
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    einfo "Hostname set to ${hostname}"
}

# system_set_keymap — Configure console keymap
system_set_keymap() {
    local keymap="${KEYMAP:-us}"
    einfo "Setting keymap: ${keymap}"

    # Void uses /etc/rc.conf for keymap
    if [[ -f /etc/rc.conf ]]; then
        if grep -q '^KEYMAP=' /etc/rc.conf; then
            sed -i "s/^KEYMAP=.*/KEYMAP=\"${keymap}\"/" /etc/rc.conf
        else
            echo "KEYMAP=\"${keymap}\"" >> /etc/rc.conf
        fi
    else
        echo "KEYMAP=\"${keymap}\"" > /etc/rc.conf
    fi

    # Also set vconsole.conf for compatibility
    echo "KEYMAP=${keymap}" > /etc/vconsole.conf

    einfo "Keymap set to ${keymap}"

    system_set_console_font
}

# _rc_conf_set — set KEY="value" in /etc/rc.conf, anchored
#
# Same shape as the KEYMAP handling above: replace an existing line or append
# one. Anchored on ^KEY= so a partial name cannot match a different setting.
_rc_conf_set() {
    local root="${CONSOLE_ROOT:-}"
    local rc="${root}/etc/rc.conf"
    local key="$1" value="$2"

    if [[ -f "${rc}" ]] && grep -q "^${key}=" "${rc}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${rc}"
    else
        mkdir -p "${root}/etc"
        printf '%s="%s"\n' "${key}" "${value}" >> "${rc}"
    fi
}

# system_set_console_font — console font via FONT= in /etc/rc.conf
#
# Void reads FONT= from the same file as KEYMAP. On a 4K/Retina panel — every
# MacBook this installer supports, among others — the default VGA font is
# effectively unreadable, and that is precisely the screen you end up on when
# the graphical session refuses to start.
#
# Empty CONSOLE_FONT means "leave it alone", which is the behaviour before this
# existed, so nothing changes for anyone who does not ask for it.
system_set_console_font() {
    local root="${CONSOLE_ROOT:-}"
    local font="${CONSOLE_FONT:-}"

    [[ -z "${font}" ]] && return 0

    # The name reaches compgen -G as a GLOB and sed as a replacement, and it can
    # arrive from a hand-edited preset or an inferred --resume config, not only
    # from the TUI list. `ter-v*` would then match a face on disk, pass
    # validation, and be written to rc.conf verbatim — where it means nothing.
    if [[ ! "${font}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        ewarn "Console font name '${font}' contains unexpected characters — ignoring"
        return 0
    fi

    # terminus-font ships the ter-* faces; verified present in the Void index
    # (terminus-font 4.49.1). Without the package the name in rc.conf would
    # point at nothing.
    if [[ ! -d "${root}/usr/share/kbd/consolefonts" ]] ||
       ! compgen -G "${root}/usr/share/kbd/consolefonts/${font}.*" >/dev/null 2>&1; then
        # NOT through try(): under --non-interactive try() calls die() on failure,
        # so a transient mirror error while fetching a COSMETIC package would
        # abort the whole install. The validation below already handles "the face
        # is not there" gracefully, which is the same outcome — minus the abort.
        xbps-install -y terminus-font >>"${LOG_FILE:-/dev/null}" 2>&1 ||
            ewarn "Could not install terminus-font — continuing without a custom console font"
    fi

    # Validate against the TARGET system, not the live medium — the font list in
    # the TUI is hard-coded (the live ISO cannot see what the install will have),
    # so this is the first point where the name can actually be checked. A bad
    # FONT= is not fatal at boot, but it silently leaves the console unreadable,
    # which is the exact thing this is meant to fix.
    if ! compgen -G "${root}/usr/share/kbd/consolefonts/${font}.*" >/dev/null 2>&1; then
        ewarn "Console font '${font}' not found in the target — leaving FONT unset"
        return 0
    fi

    _rc_conf_set FONT "${font}"
    einfo "Console font set to ${font}"
}

# generate_fstab — Generate /etc/fstab
generate_fstab() {
    einfo "Generating /etc/fstab..."

    local fstab="/etc/fstab"

    {
        echo "# /etc/fstab"
        echo "# Generated by ${INSTALLER_NAME} v${INSTALLER_VERSION}"
        echo "#"
        echo "# <fs>                                  <mountpoint>  <type>  <opts>                                  <dump/pass>"

        # Root filesystem
        local root_uuid
        root_uuid=$(get_uuid "${ROOT_PARTITION}") || true

        if [[ -n "${root_uuid}" ]]; then
            if [[ "${FILESYSTEM}" == "btrfs" && -n "${BTRFS_SUBVOLUMES:-}" ]]; then
                local IFS=':'
                local -a parts
                read -ra parts <<< "${BTRFS_SUBVOLUMES}"
                local idx
                for (( idx = 0; idx < ${#parts[@]}; idx += 2 )); do
                    local subvol="${parts[$idx]}"
                    local mpoint="${parts[$((idx + 1))]}"
                    local pass=2
                    [[ "${mpoint}" == "/" ]] && pass=1
                    echo "UUID=${root_uuid}   ${mpoint}          btrfs   subvol=${subvol},compress=zstd,noatime,defaults  0 ${pass}"
                done
            else
                echo "UUID=${root_uuid}   /             ${FILESYSTEM}    noatime,defaults        0 1"
            fi
        else
            echo "${ROOT_PARTITION}              /             ${FILESYSTEM:-ext4}     noatime,defaults        0 1"
        fi

        # ESP partition
        if [[ -n "${ESP_PARTITION:-}" ]]; then
            local esp_uuid
            esp_uuid=$(get_uuid "${ESP_PARTITION}") || true
            if [[ -n "${esp_uuid}" ]]; then
                echo "UUID=${esp_uuid}   /boot/efi     vfat    noatime,defaults        0 2"
            else
                echo "${ESP_PARTITION}              /boot/efi     vfat    noatime,defaults        0 2"
            fi
        fi

        # Swap partition
        if [[ "${SWAP_TYPE:-}" == "partition" && -n "${SWAP_PARTITION:-}" ]]; then
            local swap_uuid
            swap_uuid=$(get_uuid "${SWAP_PARTITION}") || true
            if [[ -n "${swap_uuid}" ]]; then
                echo "UUID=${swap_uuid}   none          swap    sw              0 0"
            else
                echo "${SWAP_PARTITION}              none          swap    sw              0 0"
            fi
        fi

        # tmpfs for /tmp
        echo "tmpfs                                   /tmp          tmpfs   defaults,nosuid,nodev   0 0"

    } > "${fstab}"

    einfo "fstab generated"
}

# install_filesystem_tools — Install filesystem utilities
install_filesystem_tools() {
    local fs="${FILESYSTEM:-ext4}"
    einfo "Installing filesystem tools for ${fs}..."

    local -a fs_pkgs=()

    case "${fs}" in
        ext4)   fs_pkgs+=("e2fsprogs") ;;
        btrfs)  fs_pkgs+=("btrfs-progs") ;;
        xfs)    fs_pkgs+=("xfsprogs") ;;
    esac

    # Always need dosfstools for ESP
    fs_pkgs+=("dosfstools")

    if [[ ${#fs_pkgs[@]} -gt 0 ]]; then
        try "Installing filesystem tools" xbps-install -y "${fs_pkgs[@]}"
    fi

    einfo "Filesystem tools installed"
}

# system_create_users — Create root password and user account
system_create_users() {
    einfo "Creating users..."

    # Set root password (pipe hash to avoid exposure in process list)
    if [[ -n "${ROOT_PASSWORD_HASH:-}" ]]; then
        einfo "Setting root password"
        bash -c 'echo "root:$1" | chpasswd -e' -- "${ROOT_PASSWORD_HASH}"
    else
        # A resume that could not recover the config reaches this with an empty
        # hash. Silently leaving the ROOTFS's locked '*' root password plus no
        # user account produces a system nobody can log into — say so loudly.
        ewarn "ROOT_PASSWORD_HASH is empty — root password NOT set!"
        ewarn "The ROOTFS ships root locked ('*'). Unless a user account with"
        ewarn "sudo is created below, this system will not be loginnable."
        ewarn "Recover from a live medium: chroot in and run 'passwd'."
    fi

    # Create regular user
    if [[ -n "${USERNAME:-}" ]]; then
        local groups="${USER_GROUPS:-wheel,audio,video,input,storage,network}"

        # Filter out groups that don't exist on the target system
        local valid_groups=""
        local g
        IFS=',' read -ra _groups <<< "${groups}"
        for g in "${_groups[@]}"; do
            if getent group "${g}" &>/dev/null; then
                valid_groups+="${valid_groups:+,}${g}"
            else
                ewarn "Group '${g}' does not exist, skipping"
            fi
        done
        groups="${valid_groups:-wheel}"

        einfo "Creating user: ${USERNAME}"
        if ! id "${USERNAME}" &>/dev/null; then
            try "Creating user ${USERNAME}" \
                useradd -m -G "${groups}" -s /bin/bash "${USERNAME}"
        fi

        if [[ -n "${USER_PASSWORD_HASH:-}" ]]; then
            try "Setting user password" \
                bash -c 'echo "$1:$2" | chpasswd -e' -- "${USERNAME}" "${USER_PASSWORD_HASH}"
        fi

        # Configure sudo
        try "Installing sudo" xbps-install -y sudo

        if ! _configure_sudo_wheel; then
            # With no root password (locked '*' from the ROOTFS) and no working
            # sudo, nobody can administer — or in the worst case even log into —
            # this machine. That is worth aborting for, not warning about.
            if [[ -z "${ROOT_PASSWORD_HASH:-}" ]]; then
                die "Could not grant sudo to the wheel group and root has no password — the installed system would be unadministrable."
            fi
            ewarn "Could not grant sudo to the wheel group — ${USERNAME} will have to su to root."
        fi

        einfo "User ${USERNAME} created with groups: ${groups}"
    fi
}

# _configure_sudo_wheel — grant sudo to the wheel group
#
# Used to be two `sed`s un-commenting the %wheel line in /etc/sudoers, both with
# `|| true`. If upstream ever changes that comment (a space, a tab, a different
# variant of the entry), neither pattern matches, `|| true` swallows it and the
# user gets a system with NO sudo — discovered after the first boot, on a machine
# whose root account ships locked.
#
# A drop-in is deterministic: it does not depend on the contents of a
# package-managed file, and `visudo -cf` verifies the result. A syntax error in
# sudoers locks sudo out for everyone, so the check is not optional.
# SUDO_ROOT is empty in production; it exists so this is testable off a live machine.
_configure_sudo_wheel() {
    local root="${SUDO_ROOT:-}"
    local sudoers="${root}/etc/sudoers"
    local dropin="${root}/etc/sudoers.d/10-wheel"

    # No /etc/sudoers at all means sudo is not installed — which happens for real:
    # `try "Installing sudo"` can fail and the operator can choose "continue".
    # Writing a drop-in then produces a file nothing will ever read, and the
    # function would report success, defeating the die() gate below it.
    if [[ ! -f "${sudoers}" ]]; then
        eerror "${sudoers} does not exist — sudo is not installed, a drop-in would be dead weight"
        return 1
    fi

    # The whole approach rests on one condition: /etc/sudoers must actually pull
    # the directory in. Modern sudo writes `@includedir`, older ones `#includedir`
    # — both are live directives, not comments.
    if ! grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d' "${sudoers}"; then
        ewarn "/etc/sudoers does not include /etc/sudoers.d — falling back to editing it directly"
        sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' "${sudoers}" 2>/dev/null || true
        sed -i 's/^# \(%wheel ALL=(ALL) ALL\)/\1/' "${sudoers}" 2>/dev/null || true
        if grep -Eq '^[[:space:]]*%wheel[[:space:]]+ALL=' "${sudoers}"; then
            einfo "Granted sudo to wheel (edited /etc/sudoers)"
            return 0
        fi
        eerror "Could not enable sudo for the wheel group in ${sudoers#"${root}"}"
        return 1
    fi

    mkdir -p "${root}/etc/sudoers.d" || return 1
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > "${dropin}" || return 1
    chmod 0440 "${dropin}" || return 1

    # visudo may be missing in a minimal chroot — that is a reason to skip the
    # check, not to undo a drop-in whose content we control and know is valid.
    if command -v visudo >/dev/null 2>&1; then
        if ! visudo -cf "${dropin}" >/dev/null 2>&1; then
            rm -f "${dropin}"
            eerror "visudo rejected ${dropin#"${root}"} — removed it rather than risk locking sudo out"
            return 1
        fi
    else
        ewarn "visudo not available — ${dropin#"${root}"} written without syntax verification"
    fi

    einfo "Granted sudo to wheel (${dropin#"${root}"}, mode 0440)"
    return 0
}

# Services whose absence leaves the installed system unusable rather than merely
# degraded: no device nodes (udevd), no text console to log in on (agetty-tty1),
# no session bus or seat management (dbus/elogind), no graphical login (the DMs).
# For these a failed `ln` aborts the install — the alternative is that the user
# finds out after the reboot, on a machine they cannot log into.
_CRITICAL_SERVICES="udevd dbus elogind agetty-tty1 sddm gdm greetd"

# _service_not_enabled — record a service that did not get enabled
#
# CONTRACT: this returns 0 for anything not on the critical list, and callers
# rely on that. install.sh runs under `set -Eeuo pipefail` with inherit_errexit
# and every one of the ~22 call sites is a BARE command, so a non-zero return
# from _enable_service kills the whole installer mid-chroot. That is not
# hypothetical: `try()` offers "skip this step and continue", and a skipped
# `xbps-install` leaves /etc/sv/<service> missing a few lines later — which used
# to be a warning and would have become an abort after the bootloader phase,
# with the target still mounted and system_finalize never run.
#
# The point of verifying the symlink was to stop failures being INVISIBLE, not
# to make them fatal. So the signal goes where the installer already collects
# "this step did not happen": SKIPPED_LOG, which run_post_install surfaces to
# the user at the end.
_service_not_enabled() {
    local service="$1" reason="$2"

    if [[ " ${_CRITICAL_SERVICES} " == *" ${service} "* ]]; then
        die "Failed to enable critical service: ${service} — ${reason}. The installed system would come up without it."
    fi

    ewarn "Service NOT enabled: ${service} — ${reason}"
    { printf '%s\t%s\tcmd: %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')" \
        "Enabling runit service ${service}" "_enable_service ${service}" \
        >> "${SKIPPED_LOG}"; } 2>/dev/null || true
    return 0
}

# _enable_service — Enable a runit service
#
# Verifies that the symlink actually appeared AND points where it should. It used
# to just `ln … || true` and log "Enabled" unconditionally, so a failure was
# indistinguishable from success: the install log claimed every service was on
# while the system came up without a display manager. SERVICE_ROOT exists to make
# that path testable off a live machine; it is empty in production, so the paths
# stay absolute as before.
#
# Returns 0 for a non-critical failure ON PURPOSE — see _service_not_enabled.
_enable_service() {
    local service="$1"
    local root="${SERVICE_ROOT:-}"

    if [[ ! -d "${root}/etc/sv/${service}" ]]; then
        _service_not_enabled "${service}" "no /etc/sv/${service} (package not installed?)"
        return 0
    fi

    # /var/service is only a pointer: symlink → /etc/runit/runsvdir/current →
    # default. Both links are created by the runit-void INSTALL script at
    # post-install time — the void-packages template deletes them at build time
    # on purpose ("Enable services at post-install time instead"). So inside a
    # chroot where xbps-reconfigure has not run yet, /var/service is a DANGLING
    # symlink and `ln` into it fails. Fall back to the physical directory, which
    # is what the official Void installer links into anyway.
    local svcdir="${root}/var/service"
    if [[ ! -d "${svcdir}/" ]]; then
        svcdir="${root}/etc/runit/runsvdir/default"
        mkdir -p "${svcdir}" 2>/dev/null || true
    fi

    # -n is not optional. runit-void enables agetty-tty1..6 and udevd itself, so
    # by the time system_finalize re-enables them the target is ALREADY a symlink
    # to a directory — and plain `ln -sf` dereferences it, creating a
    # self-referential /etc/sv/agetty-tty1/agetty-tty1 inside the service dir
    # instead of refreshing the link. The old `-L` check would still have seen
    # the pre-existing link and reported success.
    ln -sfn "/etc/sv/${service}" "${svcdir}/${service}" 2>/dev/null || true

    # Check the TARGET, not just that something is there — see above.
    if [[ -L "${svcdir}/${service}" ]] &&
       [[ "$(readlink "${svcdir}/${service}" 2>/dev/null)" == "/etc/sv/${service}" ]]; then
        einfo "Enabled runit service: ${service} (${svcdir#"${root}"})"
        return 0
    fi

    _service_not_enabled "${service}" "could not create ${svcdir#"${root}"}/${service}"
    return 0
}

# _ensure_cronie — cronie plus its runit service, idempotently
#
# Two things now need the same scheduler: snapper (timeline + cleanup) and the
# weekly fstrim below. cronie used to arrive only via the snapper path, so an
# install with snapshots disabled had nothing to run a periodic job with —
# which is exactly the case where TRIM still matters.
_ensure_cronie() {
    local root="${TRIM_ROOT:-}"

    # Check for the SERVICE directory, not for a `crond` binary. Void ships the
    # daemon as /usr/bin/cronie-crond and creates `crond` through
    # xbps-alternatives at package-configure time, so `command -v crond` can be
    # false inside a chroot where the package is installed but not yet
    # reconfigured — and false the other way round on a live medium that has its
    # own cron. /etc/sv/cronie is what _enable_service actually needs.
    if [[ ! -d "${root}/etc/sv/cronie" ]]; then
        # NOT through try(): under --non-interactive try() calls die(), and this
        # runs on the install path where an abort costs far more than a missing
        # maintenance job. A failed fetch degrades to "no periodic TRIM", loudly.
        xbps-install -y cronie >>"${LOG_FILE:-/dev/null}" 2>&1 || {
            ewarn "Could not install cronie — periodic jobs (TRIM, snapshot cleanup) will not run"
            return 0
        }
    fi
    _enable_service "cronie"
}

# _anacron_allow_on_battery — let weekly jobs run when unplugged
#
# /etc/cron.weekly on Void is driven by ANACRON, not cron directly: the cronie
# package builds with --enable-anacron and ships /etc/cron.hourly/0anacron, which
# runs `anacron -s` — and that script exits early when the machine is on battery
# unless ANACRON_RUN_ON_BATTERY_POWER=yes. Void's /etc/default/anacron ships that
# line COMMENTED OUT, so the default is "skip on battery".
#
# This installer targets laptops (MacBooks, GPD/UMPC, Surface). A laptop that
# mostly runs unplugged would therefore never trim, while the installer cheerfully
# logged "Weekly TRIM scheduled" — a second silent no-op next to the LUKS one.
# fstrim on an idle SSD costs a few seconds and negligible power, so enabling this
# is the right trade for maintenance work. It also affects the daily snapper
# cleanup, which wants to run for exactly the same reason.
_anacron_allow_on_battery() {
    local root="${TRIM_ROOT:-}"
    local conf="${root}/etc/default/anacron"

    [[ -f "${conf}" ]] || return 0

    if grep -qE '^[[:space:]]*ANACRON_RUN_ON_BATTERY_POWER=' "${conf}"; then
        sed -i 's|^[[:space:]]*ANACRON_RUN_ON_BATTERY_POWER=.*|ANACRON_RUN_ON_BATTERY_POWER=yes|' "${conf}"
    else
        printf '\n# Set by the Void installer: without this, anacron skips cron.weekly\n' >> "${conf}"
        printf '# (and cron.daily) whenever the machine is on battery — on a laptop that\n' >> "${conf}"
        printf '# means periodic TRIM and snapshot cleanup would effectively never run.\n' >> "${conf}"
        printf 'ANACRON_RUN_ON_BATTERY_POWER=yes\n' >> "${conf}"
    fi
    einfo "  anacron: weekly jobs allowed on battery power"
}

# _disk_is_rotational — true for a spinning disk
#
# Returns 1 (not rotational) when the answer is unknown as well. That is the
# deliberate direction: `fstrim -av` skips filesystems whose device does not
# support discard, so scheduling it on a device we cannot classify costs
# nothing, while NOT scheduling it on an unusual storage stack (dm, md, virtio,
# an NVMe behind a controller that hides the attribute) would silently drop TRIM
# on the machines most likely to need it.
_disk_is_rotational() {
    local disk="$1"
    local root="${TRIM_ROOT:-}"
    local name attr

    name="$(basename "${disk}")"
    attr="${root}/sys/block/${name}/queue/rotational"

    [[ -r "${attr}" ]] || return 1
    [[ "$(cat "${attr}" 2>/dev/null)" == "1" ]]
}

# setup_periodic_trim — weekly fstrim for SSDs
#
# systemd has fstrim.timer; runit has no equivalent, so without this TRIM never
# runs at all on our installs. On an SSD that means write performance degrading
# over time and cells wearing out faster.
#
# cron.weekly rather than `discard=async` in the mount options, deliberately:
# one script covers every filesystem (btrfs, ext4, xfs) instead of btrfs only,
# a weekly batch cannot stall I/O the way continuous discard does on cheap SSDs
# with poor firmware, and it plugs into the scheduler this repo already builds
# for snapper. `ssd` and `space_cache=v2` from the same source were considered
# and rejected: the first is autodetected, the second is the mkfs.btrfs default.
setup_periodic_trim() {
    local root="${TRIM_ROOT:-}"
    local disk="${TARGET_DISK:-}"

    if [[ -z "${disk}" ]]; then
        ewarn "No target disk known — skipping periodic TRIM setup"
        return 0
    fi

    if _disk_is_rotational "${disk}"; then
        einfo "Skipping periodic TRIM: ${disk} is a rotational disk"
        return 0
    fi

    _ensure_cronie
    _anacron_allow_on_battery

    mkdir -p "${root}/etc/cron.weekly"
    cat > "${root}/etc/cron.weekly/fstrim" << 'EOF'
#!/bin/sh
# Weekly TRIM — installed by the Void installer.
# runit has no fstrim.timer, so this is what keeps SSD write performance from
# degrading. `-a` covers every mounted filesystem that supports discard.
#
# Explicit PATH rather than an absolute binary path: cron runs with a minimal
# environment, and hardcoding /usr/sbin/fstrim would break silently on a layout
# where it is not there. A cron job that cannot find its binary fails quietly.
#
# --quiet-unsupported (util-linux >= 2.31) suppresses "the discard operation is
# not supported" for filesystems that cannot trim. Without it every unsupported
# mount writes to stderr once a week, and cron mails that to a root account
# nobody reads — noise that trains you to ignore cron mail.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec fstrim --quiet-unsupported -av
EOF
    chmod 0755 "${root}/etc/cron.weekly/fstrim"

    einfo "Weekly TRIM scheduled (/etc/cron.weekly/fstrim)"

    # On an encrypted install the job trims almost nothing unless the user opted
    # in, and saying "scheduled" without saying so would be misleading. dm-crypt
    # does not pass discard through unless the mapping is opened with
    # allow-discards; that default is upstream's and it is a SECURITY choice,
    # not an oversight — discard through dm-crypt leaks which blocks are in use
    # and can reveal the filesystem type through the encryption layer. Hence
    # LUKS_ALLOW_DISCARDS, asked for explicitly on the encryption screen
    # (lib/luks.sh does the wiring, verify_luks_discards checks the result).
    if [[ "${LUKS_ENABLED:-no}" == "yes" ]]; then
        if [[ "${LUKS_ALLOW_DISCARDS:-no}" == "yes" ]]; then
            einfo "LUKS with discard allowed: the weekly job trims the encrypted root too."
        else
            ewarn "LUKS is enabled: the weekly job will NOT trim the encrypted root."
            ewarn "To change that later you need BOTH 'luks,allow-discards' in /etc/crypttab"
            ewarn "(dracut ignores systemd's 'discard' spelling) AND rd.luks.allow-discards"
            ewarn "in GRUB_CMDLINE_LINUX, then dracut --force + grub-mkconfig. It leaks the"
            ewarn "used-block map through the encryption layer — your call."
        fi
    fi
}

# install_power_management — Laptop power management (battery-gated).
#
# power-profiles-daemon is what the GNOME and KDE power applets talk to; with
# nothing providing that D-Bus service the desktop shows no power profiles at
# all. thermald handles Intel thermal throttling — it matters more, not less,
# on fanless machines (12" MacBook, UMPCs), where the only way to shed heat is
# to clock down in a controlled way.
install_power_management() {
    if [[ ! -d /sys/class/power_supply/BAT0 && ! -d /sys/class/power_supply/BAT1 ]]; then
        einfo "No battery detected — skipping laptop power management"
        return 0
    fi

    einfo "Battery detected — installing power management..."

    if xbps-install -y power-profiles-daemon 2>/dev/null; then
        _enable_service "power-profiles-daemon"
    else
        ewarn "power-profiles-daemon not available — desktop power profiles will be missing"
    fi

    # thermald is Intel-only; on AMD it does nothing useful.
    if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        if xbps-install -y thermald 2>/dev/null; then
            _enable_service "thermald"
        else
            ewarn "thermald not available"
        fi
    fi

    einfo "Power management installed"
}

# system_finalize — Final system configuration
system_finalize() {
    einfo "Finalizing system..."

    # Reconfigure all packages (generates initramfs, locales, etc.)
    try "Reconfiguring all packages" xbps-reconfigure -fa

    # Enable essential services
    _enable_service "agetty-tty1"
    _enable_service "agetty-tty2"
    _enable_service "agetty-tty3"
    _enable_service "udevd"

    # Clean up
    checkpoint_clear
    rm -f /tmp/void-installer.conf

    einfo "System finalization complete"
}

# _install_gum_to_target — Copy bundled gum binary to installed system
# Runs OUTSIDE chroot (from run_post_install), uses MOUNTPOINT
_install_gum_to_target() {
    local target_bin="${MOUNTPOINT}/usr/local/bin"

    # Try cached gum first (already extracted during installer run)
    if [[ -x "${GUM_CACHE_DIR:-/tmp/void-installer-gum}/gum" ]]; then
        mkdir -p "${target_bin}"
        cp "${GUM_CACHE_DIR}/gum" "${target_bin}/gum" 2>/dev/null && \
            chmod +x "${target_bin}/gum" && \
            einfo "Installed gum to /usr/local/bin/gum"
        return 0
    fi

    # Try bundled tarball
    if [[ -f "${DATA_DIR:-}/gum.tar.gz" ]]; then
        local _gum_tmp
        _gum_tmp=$(mktemp -d)
        if tar xzf "${DATA_DIR}/gum.tar.gz" -C "${_gum_tmp}" 2>/dev/null; then
            local _gum_bin
            _gum_bin=$(find "${_gum_tmp}" -name "gum" -type f | head -1)
            if [[ -n "${_gum_bin}" ]]; then
                mkdir -p "${target_bin}"
                cp "${_gum_bin}" "${target_bin}/gum"
                chmod +x "${target_bin}/gum"
                einfo "Installed gum to /usr/local/bin/gum"
            fi
        fi
        rm -rf "${_gum_tmp}"
        return 0
    fi

    ewarn "Bundled gum not found — dotfiles wizard will download it on first run"
}
