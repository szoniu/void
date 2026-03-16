#!/usr/bin/env bash
# network.sh — Network checks, mirror selection, NetworkManager installation
source "${LIB_DIR}/protection.sh"

# check_network — Verify network connectivity
check_network() {
    einfo "Checking network connectivity..."

    if has_network; then
        einfo "Network connectivity OK"
        return 0
    else
        eerror "No network connectivity"
        return 1
    fi
}

# install_network_manager — Install and enable NetworkManager (runit)
install_network_manager() {
    einfo "Installing NetworkManager..."

    try "Installing NetworkManager" xbps-install -y NetworkManager

    # Enable runit services (dbus is a dependency of NetworkManager)
    try "Enabling dbus service" ln -sf /etc/sv/dbus /var/service/dbus
    try "Enabling NetworkManager service" ln -sf /etc/sv/NetworkManager /var/service/NetworkManager

    einfo "NetworkManager installed and enabled"
}

# select_fastest_mirror — Test mirrors and select the fastest one
# This is optional and can be time-consuming
select_fastest_mirror() {
    local -a results=()
    local url

    einfo "Testing mirror speeds..."

    for url in "${VOID_MIRRORS[@]}"; do
        # Test download speed against the current/ index
        local start_time end_time elapsed
        start_time=$(date +%s%N)
        if curl -fsSL --max-time 5 -o /dev/null "${url}/current/" 2>/dev/null; then
            end_time=$(date +%s%N)
            elapsed=$(( (end_time - start_time) / 1000000 ))  # ms
            results+=("${elapsed}|${url}")
        fi
    done

    if [[ ${#results[@]} -eq 0 ]]; then
        ewarn "No mirrors responded, using default"
        echo "${VOID_MIRRORS[0]}"
        return
    fi

    # Sort by speed and return fastest
    local fastest
    fastest=$(printf '%s\n' "${results[@]}" | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)
    einfo "Fastest mirror: ${fastest}"
    echo "${fastest}"
}
