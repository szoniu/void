#!/usr/bin/env bash
# tui/wifi_config.sh — Wi-Fi setup on the live medium (Forgejo issue #11).
#
# Needed because machines like the 12" MacBook have a single USB-C port and no
# ethernet at all: without Wi-Fi the installer cannot fetch the ROOTFS, let
# alone any package. The screen is a no-op when the network already works, so
# wired setups never see it.
#
# Two backends, picked at runtime:
#   - NetworkManager, when the live medium runs it (every desktop-flavour Void
#     ISO: xfce, gnome, kde...). Fighting NM with a hand-started wpa_supplicant
#     breaks the link instead of creating one, so there we write a keyfile and
#     let NM bring it up.
#   - wpa_supplicant + dhcpcd otherwise (the `base` flavour has iw,
#     wpa_supplicant, dhcpcd and linux-firmware-network via base-system and
#     linux-base, so nothing extra is needed).
#
# The passphrase never appears in a command line: wpa_passphrase reads it from
# stdin, and only the derived 64-hex PSK is ever written — including into the
# NM keyfile, which is the same file later carried to the installed system.
source "${LIB_DIR}/protection.sh"

# Where the NetworkManager profile is staged for the installed system.
: "${WIFI_PROFILE_STAGE:=/tmp/void-installer-wifi.nmconnection}"

screen_wifi_config() {
    # Already online (ethernet, tethering, or a previous pass) — nothing to do.
    if has_network; then
        einfo "Network is already up — skipping Wi-Fi configuration"
        return "${TUI_NEXT}"
    fi

    local -a ifaces=()
    local wif
    while IFS= read -r wif; do
        [[ -n "${wif}" ]] && ifaces+=("${wif}")
    done < <(_wifi_list_interfaces)

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        dialog_msgbox "No Network" \
            "No network connection and no Wi-Fi interface was found.\n\n\
If this machine has a Broadcom card, the live medium may be\n\
missing its firmware — check with:  dmesg | grep brcmfmac\n\n\
Connect a USB ethernet adapter (or USB tethering from a phone)\n\
and go back to this screen."
        return "${TUI_BACK}"
    fi

    local iface="${ifaces[0]}"
    if [[ ${#ifaces[@]} -gt 1 ]]; then
        local -a iface_items=()
        local i
        for i in "${ifaces[@]}"; do
            iface_items+=("${i}" "Wireless interface")
        done
        iface=$(dialog_menu "Select Wi-Fi Interface" "${iface_items[@]}") \
            || return "${TUI_BACK}"
    fi

    _wifi_bring_up "${iface}" || {
        dialog_msgbox "Interface Error" \
            "Could not bring up ${iface}.\n\nCheck 'rfkill list' and 'dmesg | tail'."
        return "${TUI_BACK}"
    }

    # Scan and let the user pick an SSID (or type a hidden one).
    # _wifi_pick_ssid draws dialogs, so it returns via _WIFI_SSID rather than
    # stdout — capturing it in $() would swallow the UI along with the value.
    _WIFI_SSID=""
    _wifi_pick_ssid "${iface}" || return "${TUI_BACK}"
    local ssid="${_WIFI_SSID}"
    [[ -z "${ssid}" ]] && return "${TUI_BACK}"

    local psk_hex="" open_network=0
    local passphrase
    passphrase=$(dialog_passwordbox "Wi-Fi Password" \
        "Passphrase for \"${ssid}\"\n\n(leave empty for an open network):") \
        || return "${TUI_BACK}"

    if [[ -z "${passphrase}" ]]; then
        open_network=1
    else
        # wpa_passphrase reads the passphrase from stdin, so it never shows up
        # in `ps`. Output is the derived 64-hex PSK.
        psk_hex=$(printf '%s\n' "${passphrase}" | wpa_passphrase "${ssid}" 2>/dev/null \
            | sed -n 's/^[[:space:]]*psk=\([0-9a-fA-F]\{64\}\)$/\1/p' | head -1) || true

        if [[ -z "${psk_hex}" ]]; then
            dialog_msgbox "Invalid Passphrase" \
                "Could not derive a key for \"${ssid}\".\n\n\
WPA passphrases must be 8-63 characters."
            return "${TUI_BACK}"
        fi
    fi

    dialog_infobox "Connecting" "Associating with \"${ssid}\" on ${iface}..."

    if ! _wifi_connect "${iface}" "${ssid}" "${psk_hex}" "${open_network}"; then
        dialog_msgbox "Connection Failed" \
            "Could not connect to \"${ssid}\".\n\n\
Common causes: wrong passphrase, 5 GHz-only network the\n\
card's firmware does not support, or a captive portal.\n\n\
Log: ${LOG_FILE:-/tmp/void-installer.log}"
        return "${TUI_BACK}"
    fi

    _wifi_stage_nm_profile "${ssid}" "${psk_hex}" "${open_network}"

    dialog_msgbox "Connected" \
        "Wi-Fi is up on ${iface} (\"${ssid}\").\n\n\
The network was saved for the installed system, so the first\n\
boot comes up online via NetworkManager."

    return "${TUI_NEXT}"
}

# _wifi_list_interfaces — Print wireless interface names, one per line.
_wifi_list_interfaces() {
    local dir name
    for dir in /sys/class/net/*/wireless; do
        [[ -d "${dir}" ]] || continue
        name="${dir%/wireless}"
        printf '%s\n' "${name##*/}"
    done
}

# _wifi_bring_up — rfkill unblock + link up.
_wifi_bring_up() {
    local iface="$1"

    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi 2>/dev/null || true
    fi

    ip link set "${iface}" up 2>/dev/null || return 1

    # Give the card a moment to come out of reset before scanning.
    sleep 2
    return 0
}

# _wifi_pick_ssid — Scan, present SSIDs, set _WIFI_SSID to the choice.
_wifi_pick_ssid() {
    local iface="$1"

    dialog_infobox "Scanning" "Scanning for Wi-Fi networks on ${iface}..."

    local -a ssids=()
    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        ssids+=("${line}")
    done < <(_wifi_scan_ssids "${iface}")

    local -a menu_items=()
    local s
    for s in "${ssids[@]}"; do
        menu_items+=("${s}" "Wi-Fi network")
    done
    menu_items+=("__manual__" "Enter SSID manually (hidden network)")

    local choice
    choice=$(dialog_menu "Select Wi-Fi Network" "${menu_items[@]}") || return 1

    if [[ "${choice}" == "__manual__" ]]; then
        choice=$(dialog_inputbox "Wi-Fi Network" "Enter the SSID:" "") || return 1
    fi

    _WIFI_SSID="${choice}"
    return 0
}

# _wifi_scan_ssids — Print unique, non-empty SSIDs seen by `iw scan`.
# Falls back to an empty list (hidden-network entry still offered) when the
# scan fails, which happens on cards that need a moment longer after reset.
_wifi_scan_ssids() {
    local iface="$1"

    if _wifi_nm_active; then
        nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null \
            | grep -v '^$' | sort -u | head -40 || true
        return 0
    fi

    iw dev "${iface}" scan 2>/dev/null \
        | sed -n 's/^[[:space:]]*SSID: \(.\+\)$/\1/p' \
        | grep -v '^[[:space:]]*$' \
        | sort -u \
        | head -40 || true
}

# _wifi_connect — Write a wpa_supplicant config, associate, then DHCP.
_wifi_connect() {
    local iface="$1" ssid="$2" psk_hex="$3" open_network="$4"

    if _wifi_nm_active; then
        _wifi_connect_nm "${ssid}" "${psk_hex}" "${open_network}"
        return $?
    fi

    local conf="/tmp/void-installer-wpa-${iface}.conf"
    local old_umask
    old_umask=$(umask)
    umask 077

    {
        echo "ctrl_interface=/run/wpa_supplicant"
        echo "network={"
        # printf %q keeps an SSID with spaces or quotes from breaking the file
        printf '    ssid=%s\n' "\"${ssid//\"/\\\"}\""
        if [[ "${open_network}" == "1" ]]; then
            echo "    key_mgmt=NONE"
        else
            echo "    psk=${psk_hex}"
        fi
        echo "}"
    } > "${conf}"

    umask "${old_umask}"

    # A wpa_supplicant left over from the live medium's own autoconfig would
    # hold the interface; stop it first.
    pkill -f "wpa_supplicant.*${iface}" 2>/dev/null || true
    sleep 1

    if ! wpa_supplicant -B -i "${iface}" -c "${conf}" >>"${LOG_FILE:-/dev/null}" 2>&1; then
        return 1
    fi

    # Wait for association before asking for a lease.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if iw dev "${iface}" link 2>/dev/null | grep -q "Connected to"; then
            break
        fi
        sleep 1
    done

    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd "${iface}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    elif command -v dhclient >/dev/null 2>&1; then
        dhclient "${iface}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    fi

    # Live media often lack a resolver even once the lease is in.
    ensure_dns || true

    for i in 1 2 3 4 5 6 7 8 9 10; do
        if has_network; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# _wifi_stage_nm_profile — Write a NetworkManager keyfile for the installed
# system. Only the derived PSK is stored, never the typed passphrase.
_wifi_stage_nm_profile() {
    local ssid="$1" psk_hex="$2" open_network="$3"

    _wifi_write_nm_keyfile "${WIFI_PROFILE_STAGE}" "${ssid}" "${psk_hex}" "${open_network}"
    chmod 600 "${WIFI_PROFILE_STAGE}" 2>/dev/null || true

    einfo "Wi-Fi profile staged at ${WIFI_PROFILE_STAGE}"
}

# _wifi_nm_active — True when NetworkManager is running on the live medium.
# Desktop-flavour Void ISOs (xfce, gnome, kde, ...) enable it by default; the
# base flavour does not ship it at all.
_wifi_nm_active() {
    command -v nmcli >/dev/null 2>&1 || return 1
    nmcli -t -f RUNNING general 2>/dev/null | grep -q '^running$'
}

# _wifi_connect_nm — Connect through NetworkManager by dropping in a keyfile.
# `nmcli device wifi connect ... password X` would put the passphrase in argv
# (visible in ps); a keyfile with the derived PSK avoids that entirely and is
# byte-identical to what the installed system will get.
_wifi_connect_nm() {
    local ssid="$1" psk_hex="$2" open_network="$3"

    local profile="/etc/NetworkManager/system-connections/${ssid}.nmconnection"
    mkdir -p /etc/NetworkManager/system-connections

    _wifi_write_nm_keyfile "${profile}" "${ssid}" "${psk_hex}" "${open_network}" || return 1
    chmod 600 "${profile}" 2>/dev/null || true

    nmcli connection reload >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    nmcli connection up "${ssid}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true

    ensure_dns || true

    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if has_network; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# _wifi_write_nm_keyfile — Write one NetworkManager keyfile.
# Shared by the live-medium connection and the profile staged for the target,
# so both can never drift apart.
_wifi_write_nm_keyfile() {
    local path="$1" ssid="$2" psk_hex="$3" open_network="$4"

    local old_umask
    old_umask=$(umask)
    umask 077

    {
        echo "[connection]"
        echo "id=${ssid}"
        echo "type=wifi"
        echo ""
        echo "[wifi]"
        echo "mode=infrastructure"
        echo "ssid=${ssid}"
        if [[ "${open_network}" != "1" ]]; then
            echo ""
            echo "[wifi-security]"
            echo "key-mgmt=wpa-psk"
            echo "psk=${psk_hex}"
        fi
        echo ""
        echo "[ipv4]"
        echo "method=auto"
        echo ""
        echo "[ipv6]"
        echo "method=auto"
    } > "${path}"

    umask "${old_umask}"
}
