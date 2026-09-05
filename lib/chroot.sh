#!/usr/bin/env bash
# chroot.sh — Enter/exit chroot, bind mounts, cleanup
source "${LIB_DIR}/protection.sh"

# chroot_setup — Prepare chroot environment with bind mounts
chroot_setup() {
    einfo "Setting up chroot environment..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would set up chroot"
        return 0
    fi

    # Bind mount /proc
    if ! mountpoint -q "${MOUNTPOINT}/proc" 2>/dev/null; then
        try "Mounting /proc" mount --types proc /proc "${MOUNTPOINT}/proc"
    fi

    # Bind mount /sys
    if ! mountpoint -q "${MOUNTPOINT}/sys" 2>/dev/null; then
        try "Mounting /sys" mount --rbind /sys "${MOUNTPOINT}/sys"
        mount --make-rslave "${MOUNTPOINT}/sys"
    fi

    # Bind mount /dev
    if ! mountpoint -q "${MOUNTPOINT}/dev" 2>/dev/null; then
        try "Mounting /dev" mount --rbind /dev "${MOUNTPOINT}/dev"
        mount --make-rslave "${MOUNTPOINT}/dev"
    fi

    # Bind mount /run
    if ! mountpoint -q "${MOUNTPOINT}/run" 2>/dev/null; then
        try "Mounting /run" mount --bind /run "${MOUNTPOINT}/run"
        mount --make-slave "${MOUNTPOINT}/run"
    fi

    # Mount /dev/shm as tmpfs if needed
    if ! mountpoint -q "${MOUNTPOINT}/dev/shm" 2>/dev/null; then
        if [[ -L /dev/shm ]]; then
            local target
            target=$(readlink /dev/shm)
            mkdir -p "${MOUNTPOINT}/${target}"
            mount --types tmpfs tmpfs "${MOUNTPOINT}/${target}"
        fi
    fi

    einfo "Chroot environment ready"
}

# chroot_teardown — Clean up bind mounts
chroot_teardown() {
    einfo "Tearing down chroot environment..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would tear down chroot"
        return 0
    fi

    # Unmount all mount points under MOUNTPOINT in reverse order
    # This handles recursive bind mounts from --rbind /sys and /dev
    local -a mounts
    readarray -t mounts < <(awk -v mp="${MOUNTPOINT}" '$2 ~ "^"mp"/(proc|sys|dev|run)" {print $2}' /proc/mounts 2>/dev/null | sort -r)

    local mnt
    for mnt in "${mounts[@]}"; do
        [[ -z "${mnt}" ]] && continue
        umount -l "${mnt}" 2>/dev/null || true
    done

    einfo "Chroot teardown complete"
}

# chroot_exec — Execute a command inside the chroot
chroot_exec() {
    local cmd
    cmd=$(printf '%q ' "$@")

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would chroot exec: ${cmd}"
        return 0
    fi

    chroot "${MOUNTPOINT}" /bin/bash -c "${cmd}"
}

# copy_dns_info — Copy DNS resolver config to chroot
copy_dns_info() {
    einfo "Copying DNS configuration to chroot..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would copy DNS info"
        return 0
    fi

    # Remove symlink if it exists (may be a symlink to a resolver stub)
    if [[ -L "${MOUNTPOINT}/etc/resolv.conf" ]]; then
        rm "${MOUNTPOINT}/etc/resolv.conf"
    fi

    cp -L /etc/resolv.conf "${MOUNTPOINT}/etc/resolv.conf"
    einfo "DNS configuration copied"
}

# drop_dns_info — remove the live medium's resolv.conf from the target
#
# The counterpart to copy_dns_info(). That one puts the live ISO's resolv.conf
# into the chroot so XBPS can resolve names; without removing it, the installed
# system boots with the DNS server of whatever network the install ran on frozen
# in place (or the 8.8.8.8 that ensure_dns() adds). NetworkManager only rewrites
# that file under some rc-manager settings, so the symptom is the confusing one:
# the network is up, ping by IP works, by name it does not.
#
# Deliberately HERE and not in system_finalize(): that phase is gated by the
# `finalize` checkpoint, while copy_dns_info runs unconditionally on EVERY entry
# into the chroot phase. Pairing them across that boundary meant a resumed
# install put the file back and nothing ever took it away again. Running it from
# the caller also puts it after the after_finalize hook, which is documented in
# README and may well need name resolution.
drop_dns_info() {
    einfo "Removing the live medium's resolv.conf from the target..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would remove ${MOUNTPOINT}/etc/resolv.conf"
        return 0
    fi

    # If the networking phase was skipped (try() offers exactly that), nothing in
    # the target will regenerate the file — then a frozen resolver beats none.
    if [[ ! -d "${MOUNTPOINT}/etc/sv/NetworkManager" ]]; then
        ewarn "NetworkManager not installed in the target — keeping resolv.conf, nothing would regenerate it"
        return 0
    fi

    rm -f "${MOUNTPOINT}/etc/resolv.conf"
    einfo "Removed — NetworkManager regenerates it on first boot"
}

# copy_installer_to_chroot — Copy the installer to chroot for re-invocation
copy_installer_to_chroot() {
    einfo "Copying installer to chroot..."

    if [[ "${DRY_RUN}" == "1" ]]; then
        einfo "[DRY-RUN] Would copy installer to chroot"
        return 0
    fi

    local dest="${MOUNTPOINT}${CHROOT_INSTALLER_DIR}"
    mkdir -p "${dest}"

    # Copy installer files (exclude .git, tests, and temp files)
    if command -v rsync &>/dev/null; then
        rsync -a --exclude='.git' --exclude='tests' --exclude='*.HEIC' \
            "${SCRIPT_DIR}/" "${dest}/"
    else
        cp -a "${SCRIPT_DIR}/"* "${dest}/"
        rm -rf "${dest}/.git" 2>/dev/null || true
    fi
    # Copy config file
    cp "${CONFIG_FILE}" "${dest}/$(basename "${CONFIG_FILE}")"

    # Ensure scripts are executable
    chmod +x "${dest}/install.sh" "${dest}/configure.sh"

    # Carry the staged LUKS keyfile into the chroot's /tmp; lib/luks.sh moves
    # it onto the encrypted root and shreds this copy.
    local luks_stage="${LUKS_KEYFILE_STAGE:-/tmp/void-installer-luks.key}"
    if [[ -f "${luks_stage}" ]]; then
        mkdir -p "${MOUNTPOINT}/tmp"
        install -m 000 "${luks_stage}" "${MOUNTPOINT}${luks_stage}" 2>/dev/null \
            || ewarn "Could not stage LUKS keyfile inside chroot"
    fi

    # Carry the staged Wi-Fi keyfile into the chroot's /tmp so the networking
    # phase can install it (a Wi-Fi-only machine must boot online).
    local wifi_stage="${WIFI_PROFILE_STAGE:-/tmp/void-installer-wifi.nmconnection}"
    if [[ -f "${wifi_stage}" ]]; then
        mkdir -p "${MOUNTPOINT}/tmp"
        install -m 600 "${wifi_stage}" "${MOUNTPOINT}${wifi_stage}" 2>/dev/null \
            || ewarn "Could not stage Wi-Fi profile inside chroot"
    fi

    einfo "Installer copied to ${CHROOT_INSTALLER_DIR}"
}
