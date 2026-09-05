#!/usr/bin/env bash
# luks.sh — Chroot-side LUKS wiring: crypttab, initramfs, keyfile, GRUB.
#
# The container itself is created in lib/disk.sh (outer process, where the
# passphrase lives). This module makes the installed system able to open it at
# boot, which on Void means three separate things:
#
#   1. /etc/crypttab — what dracut reads to know a container exists
#   2. /etc/dracut.conf.d — the `crypt` module plus the keyfile, both of which
#      have to be inside the initramfs image
#   3. /etc/default/grub — GRUB_ENABLE_CRYPTODISK, because /boot lives on the
#      encrypted root: GRUB must open the container to read the kernel at all
#
# The two-passphrase problem: GRUB asks once to read /boot, then the initramfs
# asks again to mount root. A keyfile embedded in the initramfs removes the
# second prompt. That is only safe because the initramfs itself sits on the
# encrypted root — hence the hard guard against a separate /boot.
source "${LIB_DIR}/protection.sh"

# Where the outer process leaves the keyfile it already added to the container.
: "${LUKS_KEYFILE_STAGE:=/tmp/void-installer-luks.key}"
: "${LUKS_KEYFILE_TARGET:=/boot/luks-keyfile}"
# Overridable so the writers can be exercised outside a real chroot.
: "${LUKS_CRYPTTAB:=/etc/crypttab}"
: "${LUKS_DRACUT_CONF:=/etc/dracut.conf.d/10-luks.conf}"

# luks_configure_system — Entry point for the chroot phase.
luks_configure_system() {
    [[ "${LUKS_ENABLED:-no}" == "yes" ]] || return 0

    einfo "Configuring LUKS support in the installed system..."

    try "Installing cryptsetup" xbps-install -y cryptsetup

    _luks_write_crypttab
    _luks_install_keyfile
    _luks_write_dracut_conf
    verify_luks_discards

    einfo "LUKS configuration complete"
}

# verify_luks_discards — Check that the TRIM opt-in actually landed.
#
# Same reason verify_wayland_only() exists in lib/desktop.sh: an installer that
# prints "TRIM is on" and ships a system where it is off has told the user a
# lie, and this one is worse than most — nothing about a silently discard-less
# disk is visible until the SSD is already slow. Every piece of this wiring is
# a token or a file whose absence is silent, so check the result, not the
# intent. Never fatal: a failed check costs a warning and a note, not an
# aborted install.
verify_luks_discards() {
    [[ "${LUKS_ALLOW_DISCARDS:-no}" == "yes" ]] || return 0

    local name="${LUKS_NAME:-cryptroot}"
    local -a problems=()

    # 1. crypttab carries the token dracut actually parses
    if ! grep -q 'allow-discards' "${LUKS_CRYPTTAB}" 2>/dev/null; then
        problems+=("${LUKS_CRYPTTAB} has no allow-discards option")
    fi

    # 2. that file is inside the initramfs — Void builds a generic image, so
    #    it is there only because of our install_items line
    local img
    img=$(ls -1 /boot/initramfs-*.img 2>/dev/null | sort -V | tail -1) || true
    if [[ -n "${img}" ]] && command -v lsinitrd >/dev/null 2>&1; then
        if ! lsinitrd "${img}" 2>/dev/null | grep -q 'etc/crypttab'; then
            problems+=("/etc/crypttab is missing from ${img}")
        fi
    fi

    # 3. the live mapping — tells us whether discard works for the rest of THIS
    #    run (a resumed install can be running on a mapping opened without it)
    if command -v dmsetup >/dev/null 2>&1 && [[ -b "/dev/mapper/${name}" ]]; then
        if ! dmsetup table "${name}" 2>/dev/null | grep -q 'allow_discards'; then
            problems+=("the running mapping ${name} was opened without allow-discards (a reboot fixes this)")
        fi
    fi

    if [[ ${#problems[@]} -eq 0 ]]; then
        einfo "  TRIM verified: crypttab, initramfs and the live mapping all allow discards"
        return 0
    fi

    ewarn "TRIM was requested but could not be fully verified:"
    local p
    for p in "${problems[@]}"; do
        ewarn "  - ${p}"
    done

    {
        echo "TRIM on the encrypted root — needs attention"
        echo
        echo "You asked for TRIM (discard) on the encrypted disk, but the installer"
        echo "could not confirm every part of it:"
        echo
        for p in "${problems[@]}"; do
            echo "  - ${p}"
        done
        echo
        echo "To fix it by hand on the installed system:"
        echo "  1. /etc/crypttab options field must read: luks,allow-discards"
        echo "     (dracut ignores systemd's 'discard' spelling)"
        echo "  2. /etc/dracut.conf.d/10-luks.conf must contain:"
        echo "     install_items+=\" /etc/crypttab \""
        echo "  3. GRUB_CMDLINE_LINUX in /etc/default/grub must contain:"
        echo "     rd.luks.allow-discards"
        echo "  4. dracut --force && grub-mkconfig -o /boot/grub/grub.cfg, then reboot"
        echo
        echo "Check afterwards with: dmsetup table cryptroot | grep allow_discards"
    } > /root/POST-INSTALL-LUKS-TRIM.txt 2>/dev/null || true

    return 0
}

# _luks_write_crypttab — Name the container by UUID, never by device path
# (/dev/sda2 moves the moment a USB disk is plugged in at boot).
_luks_write_crypttab() {
    local name="${LUKS_NAME:-cryptroot}"
    local luks_uuid
    luks_uuid=$(get_uuid "${LUKS_PARTITION}")

    if [[ -z "${luks_uuid}" ]]; then
        eerror "Cannot read UUID of LUKS partition ${LUKS_PARTITION}"
        return 1
    fi

    local keyfile_field="none"
    if [[ -f "${LUKS_KEYFILE_STAGE}" ]] && _luks_keyfile_is_safe; then
        keyfile_field="${LUKS_KEYFILE_TARGET}"
    fi

    # The token is `allow-discards`, NOT the `discard` that systemd's crypttab(5)
    # documents — Void boots through dracut, and dracut's own parser is the one
    # that reads this file. Verified in dracut-ng 112 (the version Void packages),
    # modules.d/70crypt/cryptroot-ask.sh: the options loop matches exactly
    # `noauto`, `swap`, `tmp`, `allow-discards` and `header=*`; anything else —
    # `discard` included — falls through the case with no branch and is silently
    # ignored. A wrong token here fails the worst way possible: no error, no
    # discard, and a crypttab that looks correct to anyone who knows systemd.
    local options="luks"
    if [[ "${LUKS_ALLOW_DISCARDS:-no}" == "yes" ]]; then
        options="luks,allow-discards"
    fi

    printf '%s UUID=%s %s %s\n' "${name}" "${luks_uuid}" "${keyfile_field}" \
        "${options}" > "${LUKS_CRYPTTAB}"
    chmod 600 "${LUKS_CRYPTTAB}"

    einfo "  /etc/crypttab: ${name} -> UUID=${luks_uuid} (key: ${keyfile_field}, opts: ${options})"
}

# _luks_keyfile_is_safe — The keyfile trick is only acceptable while the
# initramfs is on the encrypted root. With a separate unencrypted /boot the
# key would sit in the clear next to the data it unlocks, so refuse it.
_luks_keyfile_is_safe() {
    if [[ -n "${BOOT_PARTITION:-}" ]]; then
        ewarn "Separate /boot partition — skipping keyfile (it would be unencrypted)"
        return 1
    fi
    return 0
}

# _luks_install_keyfile — Move the staged keyfile into the target system.
_luks_install_keyfile() {
    [[ -f "${LUKS_KEYFILE_STAGE}" ]] || {
        einfo "  No keyfile staged — the passphrase will be asked twice at boot"
        return 0
    }

    if ! _luks_keyfile_is_safe; then
        shred -u "${LUKS_KEYFILE_STAGE}" 2>/dev/null || rm -f "${LUKS_KEYFILE_STAGE}"
        return 0
    fi

    install -m 000 "${LUKS_KEYFILE_STAGE}" "${LUKS_KEYFILE_TARGET}" \
        || { ewarn "Could not install LUKS keyfile"; return 0; }

    shred -u "${LUKS_KEYFILE_STAGE}" 2>/dev/null || rm -f "${LUKS_KEYFILE_STAGE}"
    einfo "  Keyfile installed at ${LUKS_KEYFILE_TARGET} (mode 000, on encrypted root)"
}

# _luks_write_dracut_conf — Pull the crypt module and the keyfile into every
# initramfs dracut builds from now on, including the ones generated by future
# kernel updates.
_luks_write_dracut_conf() {
    mkdir -p "$(dirname "${LUKS_DRACUT_CONF}")"

    {
        echo "# LUKS support — written by the Void installer"
        echo 'add_dracutmodules+=" crypt "'
        # Void builds a GENERIC initramfs — its kernel hook runs plain
        # `dracut --force` and the package ships no conf.d setting hostonly —
        # and dracut's crypt module copies /etc/crypttab into the image only
        # `if [[ $hostonly ]]`. Without this line the file the installer just
        # wrote is simply absent at boot, and with it goes the `allow-discards`
        # option, the mapping name, and every other per-container setting.
        echo 'install_items+=" /etc/crypttab "'
        if [[ -f "${LUKS_KEYFILE_TARGET}" ]]; then
            # install_items puts the file inside the image; without it
            # rd.luks.key points at a path that does not exist in early boot.
            echo "install_items+=\" ${LUKS_KEYFILE_TARGET} \""
        fi
    } > "${LUKS_DRACUT_CONF}"

    einfo "  dracut configured for LUKS"

    # Rebuild now — the initramfs generated before this config existed cannot
    # open the container.
    local kver
    kver=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1) || true
    if [[ -n "${kver}" ]]; then
        try "Regenerating initramfs with LUKS support" \
            dracut --force "/boot/initramfs-${kver}.img" "${kver}"
    else
        ewarn "No kernel modules directory found — initramfs not regenerated"
    fi
}

# luks_grub_cmdline — Kernel cmdline fragment for the encrypted root.
# Echoed into GRUB_CMDLINE_LINUX by lib/bootloader.sh.
luks_grub_cmdline() {
    [[ "${LUKS_ENABLED:-no}" == "yes" ]] || return 0

    local luks_uuid
    luks_uuid=$(get_uuid "${LUKS_PARTITION}")
    [[ -n "${luks_uuid}" ]] || return 0

    local params="rd.luks.uuid=${luks_uuid}"
    if [[ -f "${LUKS_KEYFILE_TARGET}" ]]; then
        params+=" rd.luks.key=${LUKS_KEYFILE_TARGET}"
    fi
    # Deliberately the valueless form, not `rd.luks.allow-discards=${luks_uuid}`.
    # dracut's per-UUID filter is broken on the non-systemd path Void boots
    # through: cryptroot-ask.sh compares the requested UUIDs against `$luksdev`
    # (dracut-ng 112, line 123), a variable that script never assigns — so the
    # match can never succeed, and because `getargs` did return a value the
    # valueless `elif` branch is skipped too. The UUID form is a silent no-op.
    # Blanket is not a wider blast radius here: the same cmdline always carries
    # rd.luks.uuid=<uuid>, which limits early boot to unlocking THIS container.
    if [[ "${LUKS_ALLOW_DISCARDS:-no}" == "yes" ]]; then
        params+=" rd.luks.allow-discards"
    fi

    printf '%s' "${params}"
}
