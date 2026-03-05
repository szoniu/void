#!/usr/bin/env bash
# swap.sh — Swap configuration for Void Linux (zram, partition, file)
source "${LIB_DIR}/protection.sh"

# swap_setup — Configure swap based on SWAP_TYPE
swap_setup() {
    local swap_type="${SWAP_TYPE:-none}"

    case "${swap_type}" in
        zram)
            _setup_zram
            ;;
        partition)
            _setup_swap_partition
            ;;
        file)
            _setup_swap_file
            ;;
        none)
            einfo "No swap configured"
            ;;
        *)
            ewarn "Unknown swap type: ${swap_type}"
            ;;
    esac
}

# _setup_zram — Configure zram swap using zramen
_setup_zram() {
    einfo "Setting up zram swap (zramen)..."

    try "Installing zramen" xbps-install -y zramen

    # Enable zramen runit service
    _enable_service "zramen"

    einfo "zram swap configured"
}

# _setup_swap_partition — Enable swap partition
_setup_swap_partition() {
    local swap_part="${SWAP_PARTITION:-}"

    if [[ -z "${swap_part}" ]]; then
        ewarn "No swap partition specified"
        return 0
    fi

    einfo "Enabling swap partition: ${swap_part}"

    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        try "Formatting swap partition" mkswap "${swap_part}"
        try "Activating swap partition" swapon "${swap_part}"
    fi

    einfo "Swap partition enabled"
}

# _setup_swap_file — Create and enable swap file
_setup_swap_file() {
    local size_mib="${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}"
    local swap_file="/var/swapfile"

    einfo "Creating ${size_mib} MiB swap file..."

    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if [[ "${FILESYSTEM:-ext4}" == "btrfs" ]]; then
            # btrfs requires special handling for swap files
            try "Creating btrfs swap file" \
                btrfs filesystem mkswapfile --size "${size_mib}m" "${swap_file}"
        else
            install -m 0600 /dev/null "${swap_file}"
            try "Allocating swap file" \
                dd if=/dev/zero of="${swap_file}" bs=1M count="${size_mib}" status=progress
            try "Formatting swap file" mkswap "${swap_file}"
        fi

        try "Activating swap file" swapon "${swap_file}"

        # Add to fstab
        echo "${swap_file}    none    swap    sw    0 0" >> /etc/fstab
    fi

    einfo "Swap file created: ${swap_file} (${size_mib} MiB)"
}
