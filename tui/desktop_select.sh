#!/usr/bin/env bash
# tui/desktop_select.sh — Desktop environment selection: KDE Plasma vs GNOME
source "${LIB_DIR}/protection.sh"

screen_desktop_select() {
    local current="${DESKTOP_TYPE:-kde}"
    local on_kde="off" on_gnome="off"
    [[ "${current}" == "kde" ]] && on_kde="on"
    [[ "${current}" == "gnome" ]] && on_gnome="on"

    local choice
    choice=$(dialog_radiolist "Desktop Environment" \
        "kde"   "KDE Plasma — Modern desktop with SDDM"  "${on_kde}" \
        "gnome" "GNOME — Clean desktop with GDM"         "${on_gnome}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    DESKTOP_TYPE="${choice}"
    export DESKTOP_TYPE

    _screen_wayland_only_prompt || return "${TUI_BACK}"

    einfo "Desktop type: ${DESKTOP_TYPE}, Wayland-only: ${WAYLAND_ONLY:-no}"
    return "${TUI_NEXT}"
}

# _screen_wayland_only_prompt — Offer an installation without xorg-server.
#
# What this actually buys differs per desktop, so the text says so instead of
# promising "no Xorg" generically:
#   - KDE: Plasma needs only Xwayland, and SDDM has no X dependency of its
#     own — the greeter is switched to Wayland and xorg-server never lands.
#   - GNOME: GDM depends on the full xorg-server, so GDM is replaced with
#     greetd + tuigreet. Without that swap the option would be meaningless.
_screen_wayland_only_prompt() {
    local desktop="${DESKTOP_TYPE:-kde}"
    local detail=""

    if [[ "${desktop}" == "gnome" ]]; then
        detail="GNOME: GDM itself depends on xorg-server, so the login\n\
manager is replaced with greetd + tuigreet (a console\n\
greeter). GNOME runs on Wayland either way."
    else
        detail="KDE: Plasma only needs Xwayland. The SDDM greeter is\n\
switched to Wayland (kwin_wayland), which is the piece\n\
that would otherwise start an X server at boot."
    fi

    if dialog_yesno "Wayland-only Installation" \
        "Install without the X server (xorg-server)?\n\n\
${detail}\n\n\
X11 applications keep working through Xwayland.\n\
Say no if you rely on X-only tooling (screen sharing in\n\
older apps, some remote-desktop and automation tools)."; then
        WAYLAND_ONLY="yes"
    else
        WAYLAND_ONLY="no"
    fi
    export WAYLAND_ONLY

    return 0
}
