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

    # Remove symlink if it exists (systemd may create it)
    if [[ -L "${MOUNTPOINT}/etc/resolv.conf" ]]; then
        rm "${MOUNTPOINT}/etc/resolv.conf"
    fi

    cp -L /etc/resolv.conf "${MOUNTPOINT}/etc/resolv.conf"
    einfo "DNS configuration copied"
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

    einfo "Installer copied to ${CHROOT_INSTALLER_DIR}"
}
