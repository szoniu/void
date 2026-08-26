#!/usr/bin/env bash
# desktop.sh — Desktop environment installation for Void Linux
source "${LIB_DIR}/protection.sh"

# desktop_install — Install desktop environment (KDE Plasma or GNOME)
desktop_install() {
    einfo "=== Desktop Installation ==="

    _install_gpu_drivers

    local desktop="${DESKTOP_TYPE:-kde}"
    if [[ "${desktop}" == "gnome" ]]; then
        _install_gnome_desktop
        _install_gnome_apps
        _install_gnome_lang
        _configure_gnome_locale
    else
        _install_kde_plasma
        _install_kde_apps
        _install_kde_lang
        _configure_plasma_locale
    fi

    _install_bluetooth
    _install_printing

    einfo "=== Desktop installation complete ==="
}

# _install_gpu_drivers — Install GPU-specific drivers
_install_gpu_drivers() {
    local gpu="${GPU_VENDOR:-}"

    # Hybrid GPU: install iGPU drivers first, then dGPU drivers
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        case "${IGPU_VENDOR:-}" in
            intel) _install_intel_drivers ;;
            amd)   _install_amd_drivers ;;
        esac
    fi

    case "${gpu}" in
        nvidia)
            _install_nvidia_drivers
            ;;
        amd)
            # Skip if already installed as iGPU above
            if [[ "${HYBRID_GPU:-no}" != "yes" || "${IGPU_VENDOR:-}" != "amd" ]]; then
                _install_amd_drivers
            fi
            ;;
        intel)
            # Skip if already installed as iGPU above
            if [[ "${HYBRID_GPU:-no}" != "yes" || "${IGPU_VENDOR:-}" != "intel" ]]; then
                _install_intel_drivers
            fi
            ;;
        none|"")
            einfo "No GPU drivers selected"
            ;;
    esac
}

# _install_nvidia_drivers — Install NVIDIA proprietary drivers
_install_nvidia_drivers() {
    einfo "Installing NVIDIA drivers..."

    # NVIDIA requires nonfree repo
    if [[ "${ENABLE_NONFREE:-no}" != "yes" ]]; then
        ewarn "NVIDIA drivers require nonfree repo — enabling it"
        local mirror="${MIRROR_URL:-${VOID_REPO_BASE}}"
        mkdir -p /etc/xbps.d
        echo "repository=${mirror}/current/nonfree" > /etc/xbps.d/10-repository-nonfree.conf
        try "Syncing nonfree repo" xbps-install -S
    fi

    if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
        try "Installing NVIDIA open drivers" xbps-install -y nvidia nvidia-open-dkms
    else
        try "Installing NVIDIA drivers" xbps-install -y nvidia
    fi

    # Load nvidia modules at boot
    mkdir -p /etc/modules-load.d
    cat > /etc/modules-load.d/nvidia.conf << 'NVEOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
NVEOF

    # Enable DRM KMS for Wayland
    mkdir -p /etc/modprobe.d
    echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia.conf

    einfo "NVIDIA drivers installed"
}

# _install_amd_drivers — Install AMD GPU drivers (mesa)
_install_amd_drivers() {
    einfo "Installing AMD GPU drivers..."

    try "Installing AMD drivers" xbps-install -y mesa-dri vulkan-loader mesa-vulkan-radeon

    einfo "AMD GPU drivers installed"
}

# _install_intel_drivers — Install Intel GPU drivers
_install_intel_drivers() {
    einfo "Installing Intel GPU drivers..."

    try "Installing Intel drivers" xbps-install -y mesa-dri vulkan-loader mesa-vulkan-intel intel-video-accel

    einfo "Intel GPU drivers installed"
}

# _install_kde_plasma — Install KDE Plasma desktop
_install_kde_plasma() {
    einfo "Installing KDE Plasma desktop..."

    # Plasma itself only needs Xwayland (plasma-workspace depends on
    # xorg-server-xwayland, not on the full xorg-server), and SDDM pulls in
    # nothing X-related on its own — so a Wayland-only KDE really does end up
    # without xorg-server on disk.
    local -a x_pkgs=(xorg-minimal)
    if [[ "${WAYLAND_ONLY:-no}" == "yes" ]]; then
        x_pkgs=(xorg-server-xwayland)
    fi

    try "Installing KDE Plasma" xbps-install -y \
        kde5 \
        kde5-baseapps \
        "${x_pkgs[@]}" \
        sddm \
        elogind \
        dbus

    # PipeWire audio
    try "Installing PipeWire" xbps-install -y \
        pipewire \
        wireplumber \
        alsa-pipewire \
        libspa-bluetooth

    # Enable services
    _enable_service "dbus"
    _enable_service "sddm"
    _enable_service "elogind"

    # Disable conflicting services (sddm manages its own tty)
    rm -f /var/service/agetty-tty7 2>/dev/null || true

    # Configure SDDM theme
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/void.conf << 'SDDMEOF'
[Theme]
Current=breeze

[General]
InputMethod=
SDDMEOF

    if [[ "${WAYLAND_ONLY:-no}" == "yes" ]]; then
        # SDDM defaults to an X11 greeter; without this it would start
        # xorg-server at boot — which is exactly what Wayland-only avoids.
        # kwin_wayland is the compositor Plasma already ships, so no weston.
        cat > /etc/sddm.conf.d/10-wayland.conf << 'SDDMWLEOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
SDDMWLEOF
        einfo "  SDDM configured for a Wayland greeter"
    fi

    # PipeWire autostart config
    mkdir -p /etc/pipewire
    if [[ -f /usr/share/pipewire/pipewire.conf ]]; then
        cp /usr/share/pipewire/pipewire.conf /etc/pipewire/
    fi

    # PipeWire XDG autostart (Void uses runit — no system service for PipeWire)
    _create_pipewire_autostart

    einfo "KDE Plasma installed"
}

# _install_kde_apps — Install selected KDE applications
_install_kde_apps() {
    local extras="${DESKTOP_EXTRAS:-}"

    if [[ -z "${extras}" ]]; then
        return 0
    fi

    einfo "Installing KDE applications..."

    # extras is space-separated from dialog checklist (may have quotes)
    local cleaned
    cleaned=$(echo "${extras}" | tr -d '"')

    # Map app names to package names (where they differ)
    local app pkg
    for app in ${cleaned}; do
        case "${app}" in
            obs-studio) pkg="obs" ;;
            vscode)
                ewarn "vscode is not available in Void repos — skipping (install manually or use flatpak)"
                continue
                ;;
            *) pkg="${app}" ;;
        esac

        einfo "Installing optional app: ${pkg}"
        xbps-install -y "${pkg}" 2>/dev/null || ewarn "Package '${pkg}' not available, skipping"
    done

    einfo "KDE applications installed"
}

# _install_kde_lang — KDE language packs (Void bundles translations in main packages)
_install_kde_lang() {
    # Void Linux includes translations in the main KDE packages (no separate -lang/-l10n pkgs)
    # Nothing to install — locale is configured in _configure_plasma_locale
    return 0
}

# _configure_plasma_locale — Set Plasma locale for new users via skel
_configure_plasma_locale() {
    local locale="${LOCALE:-en_US.UTF-8}"
    local lang="${locale%%_*}"

    if [[ "${lang}" == "en" ]]; then
        return 0
    fi

    einfo "Configuring Plasma locale: ${locale}"

    # plasma-localerc in /etc/skel — new users get correct locale automatically
    mkdir -p /etc/skel/.config
    cat > /etc/skel/.config/plasma-localerc << PLEOF
[Formats]
LANG=${locale}

[Translations]
LANGUAGE=${lang}
PLEOF

    einfo "Plasma locale configured"
}

# _install_gnome_desktop — Install GNOME desktop
_install_gnome_desktop() {
    einfo "Installing GNOME desktop..."

    # GDM in Void depends on the full xorg-server (not just Xwayland), so a
    # Wayland-only GNOME cannot use it — the package would drag Xorg back in
    # no matter what else we leave out. greetd + tuigreet is the replacement:
    # a console greeter that launches the Wayland session directly. GNOME's
    # own components (gnome-shell, gnome-session, mutter) have no xorg-server
    # dependency, so this really does produce a system without it.
    if [[ "${WAYLAND_ONLY:-no}" == "yes" ]]; then
        try "Installing GNOME (Wayland-only)" xbps-install -y \
            gnome \
            xorg-server-xwayland \
            greetd \
            tuigreet \
            elogind \
            dbus
    else
        try "Installing GNOME" xbps-install -y \
            gnome \
            xorg-minimal \
            gdm \
            elogind \
            dbus
    fi

    # PipeWire audio
    try "Installing PipeWire" xbps-install -y \
        pipewire \
        wireplumber \
        alsa-pipewire \
        libspa-bluetooth

    # Enable services
    _enable_service "dbus"
    if [[ "${WAYLAND_ONLY:-no}" == "yes" ]]; then
        _configure_greetd "gnome-wayland"
        _enable_service "greetd"
    else
        _enable_service "gdm"
    fi
    _enable_service "elogind"

    # Disable conflicting services (the display manager owns its own tty)
    rm -f /var/service/agetty-tty7 2>/dev/null || true

    # PipeWire autostart config
    mkdir -p /etc/pipewire
    if [[ -f /usr/share/pipewire/pipewire.conf ]]; then
        cp /usr/share/pipewire/pipewire.conf /etc/pipewire/
    fi

    # PipeWire XDG autostart (Void uses runit — no system service for PipeWire)
    _create_pipewire_autostart

    einfo "GNOME installed"
}

# _install_gnome_apps — Install selected GNOME applications
_install_gnome_apps() {
    local extras="${DESKTOP_EXTRAS:-}"

    if [[ -z "${extras}" ]]; then
        return 0
    fi

    einfo "Installing GNOME applications..."

    # extras is space-separated from dialog checklist (may have quotes)
    local cleaned
    cleaned=$(echo "${extras}" | tr -d '"')

    local app
    for app in ${cleaned}; do
        einfo "Installing optional app: ${app}"
        xbps-install -y "${app}" 2>/dev/null || ewarn "Package '${app}' not available, skipping"
    done

    einfo "GNOME applications installed"
}

# _install_gnome_lang — GNOME language packs (Void bundles translations in main packages)
_install_gnome_lang() {
    # Void Linux includes translations in the main GNOME packages (no separate -locale pkgs)
    # Nothing to install — locale is configured in _configure_gnome_locale
    return 0
}

# _configure_gnome_locale — Set GNOME locale for new users via dconf + skel
_configure_gnome_locale() {
    local locale="${LOCALE:-en_US.UTF-8}"
    local lang="${locale%%_*}"

    if [[ "${lang}" == "en" ]]; then
        return 0
    fi

    einfo "Configuring GNOME locale: ${locale}"

    # dconf profile — system-wide locale override
    mkdir -p /etc/dconf/profile
    cat > /etc/dconf/profile/user << 'DCONFEOF'
user-db:user
system-db:local
DCONFEOF

    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-locale << LOCEOF
[system/locale]
region='${locale}'
format-locale='${locale}'
LOCEOF
    dconf update 2>/dev/null || true

    # Skip GNOME initial setup for new users
    mkdir -p /etc/skel/.config
    echo "yes" > /etc/skel/.config/gnome-initial-setup-done

    einfo "GNOME locale configured"
}

# _create_pipewire_autostart — Create XDG autostart entries for PipeWire
# Void uses runit (no systemd user services), so PipeWire must start per-user via XDG autostart
_create_pipewire_autostart() {
    local autostart_dir="/etc/xdg/autostart"
    mkdir -p "${autostart_dir}"

    local svc
    for svc in pipewire pipewire-pulse wireplumber; do
        cat > "${autostart_dir}/${svc}.desktop" << PWEOF
[Desktop Entry]
Type=Application
Name=${svc}
Exec=/usr/bin/${svc}
X-KDE-autostart-phase=0
PWEOF
    done

    einfo "PipeWire XDG autostart entries created"
}

# _install_bluetooth — Install Bluetooth support (auto when hardware detected)
_install_bluetooth() {
    if [[ "${BLUETOOTH_DETECTED:-0}" != "1" ]]; then
        return 0
    fi

    einfo "Installing Bluetooth support..."
    try "Installing bluez" xbps-install -y bluez
    _enable_service "bluetoothd"
    einfo "Bluetooth support installed"
}

# install_hyprland_ecosystem — Hyprland + Waybar, wofi, mako, grim, slurp, ...
#
# Void does NOT ship Hyprland: void-packages has hyprutils/hyprwayland-scanner
# (dependencies) but no Hyprland, hyprpaper, hypridle or hyprlock. The whole
# compositor stack has to come from a third-party repo. Note the package name
# is `Waybar`, capital W — `waybar` silently resolves to nothing.
install_hyprland_ecosystem() {
    if [[ "${ENABLE_HYPRLAND:-no}" != "yes" ]]; then
        return 0
    fi
    einfo "Installing Hyprland ecosystem..."

    _setup_hyprland_repo

    # Packages that only exist in the third-party repo
    local -a hypr_third_party=(
        Hyprland hyprpaper hypridle hyprlock xdg-desktop-portal-hyprland
    )
    # Packages from official Void repos
    local -a hypr_official=(
        Waybar wofi mako grim slurp wl-clipboard brightnessctl
    )

    local pkg
    for pkg in "${hypr_third_party[@]}" "${hypr_official[@]}"; do
        xbps-install -y "${pkg}" 2>/dev/null || ewarn "Package '${pkg}' not available, skipping"
    done

    if ! command -v Hyprland >/dev/null 2>&1 && ! [[ -x /usr/bin/Hyprland ]]; then
        ewarn "Hyprland itself did not install — the third-party repo may be down."
        ewarn "The rest of the Wayland tools are installed; add a working repo later."
    fi

    einfo "Hyprland ecosystem installed"
}

# _setup_hyprland_repo — Add the third-party repo carrying the Hyprland stack.
#
# A dead repository entry is worse than none: xbps reports an error on *every*
# subsequent `xbps-install -S`, and an orphaned package from a dead repo can
# block the whole system update once Void bumps a soname (xbps transactions are
# all-or-nothing). So the entry is only kept when the repo actually answers.
_setup_hyprland_repo() {
    local repo_url="https://mirror.black-hole.dev/$(xbps-uhelper arch 2>/dev/null || echo x86_64)"
    local conf="/etc/xbps.d/20-blackhole.conf"

    mkdir -p /etc/xbps.d

    # Clean up entries for repos that are known to be gone, so an upgrade path
    # from an older installer run does not keep erroring out.
    rm -f /etc/xbps.d/20-noctalia.conf /etc/xbps.d/20-hyprland-extra.conf \
          /etc/xbps.d/hyprland-void.conf /etc/xbps.d/void-extra.conf 2>/dev/null || true

    if ! curl -fsSL --max-time 15 -o /dev/null "${repo_url}/${repo_url##*/}-repodata" 2>/dev/null; then
        ewarn "Hyprland repo ${repo_url} is unreachable — skipping repo setup"
        return 0
    fi

    einfo "Adding Hyprland third-party repository: ${repo_url}"
    echo "repository=${repo_url}" > "${conf}"

    # -y accepts the repo's RSA key non-interactively; without it xbps waits
    # for a keypress that nobody can answer inside the progress screen.
    try "Syncing third-party repository" xbps-install -Sy
}

# install_gaming — Install gaming packages (Steam, gamescope, MangoHud)
install_gaming() {
    if [[ "${ENABLE_GAMING:-no}" != "yes" ]]; then
        return 0
    fi

    einfo "Installing gaming packages..."

    # Steam requires nonfree repo (32-bit libs + proprietary)
    # Void glibc supports native Steam (no Flatpak workaround needed)
    local -a gaming_pkgs=(
        steam
        gamescope
        MangoHud
        steam-udev-rules
    )

    local pkg
    for pkg in "${gaming_pkgs[@]}"; do
        xbps-install -y "${pkg}" 2>/dev/null || ewarn "Package '${pkg}' not available, skipping"
    done

    einfo "Gaming packages installed"
    einfo "Note: Run 'steam' to complete Steam setup on first launch"
}

# install_noctalia_shell — Install Noctalia Shell + Wayland compositor
install_noctalia_shell() {
    if [[ "${ENABLE_NOCTALIA:-no}" != "yes" ]]; then
        return 0
    fi

    local compositor="${NOCTALIA_COMPOSITOR:-Hyprland}"
    einfo "Installing Noctalia Shell with ${compositor}..."

    # The old noctalia-void-repo (rxelelo.github.io) is gone — a 404 entry in
    # /etc/xbps.d makes every later `xbps-install -S` fail, so it is removed
    # rather than written. Noctalia itself is not packaged for Void anywhere;
    # what the installer can do is lay down its runtime (quickshell, from the
    # official repo) and the compositor, and leave the shell to be installed
    # from upstream afterwards.
    rm -f /etc/xbps.d/20-noctalia.conf 2>/dev/null || true

    try "Installing quickshell (Noctalia runtime)" xbps-install -y quickshell

    # Install selected Wayland compositor
    _install_noctalia_compositor "${compositor}"

    # Noctalia Shell has no Void package (neither official nor third-party as
    # of this writing). Try anyway in case that changed, but never fail the
    # install over it — the compositor and quickshell are already in place.
    if ! xbps-install -y noctalia-shell 2>/dev/null; then
        ewarn "noctalia-shell is not packaged for Void — install it from upstream:"
        ewarn "  https://github.com/noctalia-dev/noctalia-shell"
        _noctalia_write_manual_note
    fi

    # Install optional runtime dependencies
    local pkg
    for pkg in cliphist wlsunset cava brightnessctl; do
        einfo "Installing Noctalia optional: ${pkg}"
        xbps-install -y "${pkg}" 2>/dev/null || ewarn "Package '${pkg}' not available, skipping"
    done

    # Configure compositor to launch Noctalia Shell
    _configure_noctalia_autostart "${compositor}"

    einfo "Noctalia Shell installed"
}

# _install_noctalia_compositor — Install the selected Wayland compositor
_install_noctalia_compositor() {
    local compositor="$1"

    case "${compositor}" in
        Hyprland)
            try "Installing Hyprland" xbps-install -y Hyprland
            ;;
        niri)
            try "Installing niri" xbps-install -y niri
            ;;
        sway)
            try "Installing Sway" xbps-install -y sway
            ;;
        *)
            ewarn "Unknown compositor: ${compositor}, skipping"
            ;;
    esac
}

# _configure_noctalia_autostart — Configure compositor to start Noctalia Shell
_configure_noctalia_autostart() {
    local compositor="$1"

    # Create config for all users via skel
    local skel="/etc/skel"

    case "${compositor}" in
        Hyprland)
            local conf_dir="${skel}/.config/hypr"
            mkdir -p "${conf_dir}"
            local kb_layout="${KEYMAP:-us}"
            cat > "${conf_dir}/hyprland.conf" << HYPREOF
# Hyprland config — generated by ${INSTALLER_NAME}

# Monitor
monitor = ,preferred,auto,1

# Appearance
general {
    gaps_in = 5
    gaps_out = 10
}

decoration {
    rounding = 20
    rounding_power = 2

    shadow {
        enabled = true
        range = 4
        render_power = 3
        color = rgba(1a1a1aee)
    }

    blur {
        enabled = true
        size = 3
        passes = 2
        vibrancy = 0.1696
    }
}

# Environment
env = QT_QPA_PLATFORM,wayland
env = MOZ_ENABLE_WAYLAND,1

# Noctalia Shell layer rules (Hyprland 0.53+ syntax)
layerrule = blur on, ignore_alpha 0.5, blur_popups on, match:namespace noctalia-background-.*

# Input
input {
    kb_layout = ${kb_layout}
    follow_mouse = 1
    touchpad {
        natural_scroll = false
    }
}

# Autostart
exec-once = dbus-update-activation-environment --systemd --all
exec-once = qs -c noctalia-shell

# Basic keybindings
\$mod = SUPER
bind = \$mod, Return, exec, konsole
bind = \$mod, Q, killactive
bind = \$mod, M, exit
bind = \$mod, V, togglefloating
bind = \$mod, F, fullscreen
bind = \$mod, left, movefocus, l
bind = \$mod, right, movefocus, r
bind = \$mod, up, movefocus, u
bind = \$mod, down, movefocus, d
bind = \$mod, 1, workspace, 1
bind = \$mod, 2, workspace, 2
bind = \$mod, 3, workspace, 3
bind = \$mod, 4, workspace, 4
bind = \$mod, 5, workspace, 5
bind = \$mod SHIFT, 1, movetoworkspace, 1
bind = \$mod SHIFT, 2, movetoworkspace, 2
bind = \$mod SHIFT, 3, movetoworkspace, 3
bind = \$mod SHIFT, 4, movetoworkspace, 4
bind = \$mod SHIFT, 5, movetoworkspace, 5

# Noctalia IPC keybindings
\$ipc = qs -c noctalia-shell ipc call
bind = \$mod, SPACE, exec, \$ipc launcher toggle
bind = \$mod, S, exec, \$ipc controlCenter toggle
bind = \$mod, comma, exec, \$ipc settings toggle
bindel = , XF86AudioRaiseVolume, exec, \$ipc volume increase
bindel = , XF86AudioLowerVolume, exec, \$ipc volume decrease
bindl = , XF86AudioMute, exec, \$ipc volume muteOutput
bindel = , XF86MonBrightnessUp, exec, \$ipc brightness increase
bindel = , XF86MonBrightnessDown, exec, \$ipc brightness decrease
HYPREOF
            ;;
        niri)
            local conf_dir="${skel}/.config/niri"
            mkdir -p "${conf_dir}"
            local kb_layout="${KEYMAP:-us}"
            cat > "${conf_dir}/config.kdl" << NIRIEOF
// Niri config — generated by ${INSTALLER_NAME}

// Environment variables
environment {
    QT_QPA_PLATFORM "wayland"
    MOZ_ENABLE_WAYLAND "1"
    ELECTRON_OZONE_PLATFORM_HINT "auto"
}

// Autostart
spawn-at-startup "dbus-update-activation-environment" "--systemd" "--all"
spawn-at-startup "qs" "-c" "noctalia-shell"

// Input
input {
    keyboard {
        xkb {
            layout "${kb_layout}"
        }
        numlock
    }

    touchpad {
        tap
        dwt
    }

    mouse {
    }
}

// Layout
layout {
    gaps 10

    center-focused-column "never"

    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }

    default-column-width { proportion 0.5; }

    focus-ring {
        width 3
        active-color "#7fc8ff"
        inactive-color "#505050"
    }

    border {
        off
    }

    shadow {
        on
        softness 30
        spread 5
        offset x=0 y=5
        color "#0007"
    }

    struts {
    }
}

// Rounded corners for all windows
window-rule {
    geometry-corner-radius 12
    clip-to-geometry true
}

// Firefox PiP floating
window-rule {
    match app-id=r#"firefox\$"# title="^Picture-in-Picture\$"
    open-floating true
}

// Noctalia Shell layer rules
layer-rule {
    match namespace="^noctalia-overview*"
    place-within-backdrop true
}

// Allow apps to steal focus (needed for tray icons, notifications)
debug {
    honor-xdg-activation-with-invalid-serial
}

// Prefer server-side decorations
prefer-no-csd

screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

hotkey-overlay {
    skip-at-startup
}

// Key bindings
binds {
    // Show hotkey help
    Mod+Shift+Slash { show-hotkey-overlay; }

    // Launch terminal
    Mod+Return { spawn "konsole"; }

    // Noctalia IPC keybindings
    Mod+Space { spawn-sh "qs -c noctalia-shell ipc call launcher toggle"; }
    Mod+S { spawn-sh "qs -c noctalia-shell ipc call controlCenter toggle"; }
    Mod+Comma { spawn-sh "qs -c noctalia-shell ipc call settings toggle"; }

    // Window management
    Mod+Q repeat=false { close-window; }
    Mod+V { toggle-window-floating; }
    Mod+Shift+V { switch-focus-between-floating-and-tiling; }
    Mod+Shift+F { fullscreen-window; }
    Mod+F { maximize-column; }
    Mod+R { switch-preset-column-width; }
    Mod+Shift+R { switch-preset-window-height; }
    Mod+C { center-column; }

    // Focus movement (arrows + vim keys)
    Mod+Left  { focus-column-left; }
    Mod+Down  { focus-window-down; }
    Mod+Up    { focus-window-up; }
    Mod+Right { focus-column-right; }
    Mod+H     { focus-column-left; }
    Mod+J     { focus-window-down; }
    Mod+K     { focus-window-up; }
    Mod+L     { focus-column-right; }

    // Move windows (arrows + vim keys)
    Mod+Ctrl+Left  { move-column-left; }
    Mod+Ctrl+Down  { move-window-down; }
    Mod+Ctrl+Up    { move-window-up; }
    Mod+Ctrl+Right { move-column-right; }
    Mod+Ctrl+H     { move-column-left; }
    Mod+Ctrl+J     { move-window-down; }
    Mod+Ctrl+K     { move-window-up; }
    Mod+Ctrl+L     { move-column-right; }

    // Monitor focus
    Mod+Shift+Left  { focus-monitor-left; }
    Mod+Shift+Down  { focus-monitor-down; }
    Mod+Shift+Up    { focus-monitor-up; }
    Mod+Shift+Right { focus-monitor-right; }

    // Move column to monitor
    Mod+Shift+Ctrl+Left  { move-column-to-monitor-left; }
    Mod+Shift+Ctrl+Down  { move-column-to-monitor-down; }
    Mod+Shift+Ctrl+Up    { move-column-to-monitor-up; }
    Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }

    // Workspace by index
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+Ctrl+1 { move-column-to-workspace 1; }
    Mod+Ctrl+2 { move-column-to-workspace 2; }
    Mod+Ctrl+3 { move-column-to-workspace 3; }
    Mod+Ctrl+4 { move-column-to-workspace 4; }
    Mod+Ctrl+5 { move-column-to-workspace 5; }

    // Workspace navigation
    Mod+Page_Down { focus-workspace-down; }
    Mod+Page_Up   { focus-workspace-up; }
    Mod+Ctrl+Page_Down { move-column-to-workspace-down; }
    Mod+Ctrl+Page_Up   { move-column-to-workspace-up; }

    // Mouse wheel workspace switching
    Mod+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
    Mod+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
    Mod+Ctrl+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
    Mod+Ctrl+WheelScrollUp   cooldown-ms=150 { move-column-to-workspace-up; }

    // Column width/height adjustments
    Mod+Minus { set-column-width "-10%"; }
    Mod+Equal { set-column-width "+10%"; }
    Mod+Shift+Minus { set-window-height "-10%"; }
    Mod+Shift+Equal { set-window-height "+10%"; }

    // Consume/expel windows into/from columns
    Mod+BracketLeft  { consume-or-expel-window-left; }
    Mod+BracketRight { consume-or-expel-window-right; }

    // Overview
    Mod+O repeat=false { toggle-overview; }

    // Screenshots
    Print { screenshot; }
    Ctrl+Print { screenshot-screen; }
    Alt+Print { screenshot-window; }

    // Volume (PipeWire / WirePlumber)
    XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "qs -c noctalia-shell ipc call volume increase"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn-sh "qs -c noctalia-shell ipc call volume decrease"; }
    XF86AudioMute        allow-when-locked=true { spawn-sh "qs -c noctalia-shell ipc call volume muteOutput"; }

    // Brightness
    XF86MonBrightnessUp   allow-when-locked=true { spawn-sh "qs -c noctalia-shell ipc call brightness increase"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn-sh "qs -c noctalia-shell ipc call brightness decrease"; }

    // Keyboard shortcuts inhibitor escape hatch
    Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }

    // Session
    Mod+Shift+E { quit; }
    Mod+Shift+P { power-off-monitors; }
}
NIRIEOF
            ;;
        sway)
            local conf_dir="${skel}/.config/sway"
            mkdir -p "${conf_dir}"
            # Environment variables for Wayland apps
            local env_dir="${skel}/.config/environment.d"
            mkdir -p "${env_dir}"
            cat > "${env_dir}/sway.conf" << 'ENVEOF'
QT_QPA_PLATFORM=wayland
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=auto
XDG_CURRENT_DESKTOP=sway
ENVEOF
            local kb_layout="${KEYMAP:-us}"
            cat > "${conf_dir}/config" << SWAYEOF
# Sway config — generated by ${INSTALLER_NAME}
# Read \`man 5 sway\` for a complete reference.

# ---------------------------------------------------------
# Variables
# ---------------------------------------------------------
set \$mod Mod4
set \$term konsole
set \$ipc qs -c noctalia-shell ipc call

# ---------------------------------------------------------
# Input — keyboard
# ---------------------------------------------------------
input type:keyboard {
    xkb_layout "${kb_layout}"
    repeat_delay 300
    repeat_rate 30
}

# ---------------------------------------------------------
# Input — touchpad
# ---------------------------------------------------------
input type:touchpad {
    tap enabled
    natural_scroll disabled
    dwt enabled
    middle_emulation enabled
    scroll_method two_finger
}

# ---------------------------------------------------------
# Appearance
# ---------------------------------------------------------
default_border pixel 2
default_floating_border pixel 2

gaps inner 5
gaps outer 5

smart_gaps on
smart_borders on

focus_follows_mouse no

floating_modifier \$mod normal

# Window colors        border  backgr. text    indicator child_border
client.focused         #7fc8ff #285577 #ffffff #7fc8ff   #7fc8ff
client.focused_inactive #333333 #1a1a1a #888888 #484e50  #333333
client.unfocused       #333333 #1a1a1a #888888 #292d2e  #222222
client.urgent          #900000 #900000 #ffffff #900000  #900000

# ---------------------------------------------------------
# Autostart
# ---------------------------------------------------------
exec dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP
exec qs -c noctalia-shell

# ---------------------------------------------------------
# Key bindings — basics
# ---------------------------------------------------------
bindsym \$mod+Return exec \$term
bindsym \$mod+q kill
bindsym \$mod+f fullscreen
bindsym \$mod+v floating toggle
bindsym \$mod+Shift+v focus mode_toggle
bindsym \$mod+Shift+c reload
bindsym \$mod+Shift+e exec swaynag -t warning \\
    -m 'Exit sway? This will end your Wayland session.' \\
    -B 'Yes, exit sway' 'swaymsg exit'

# ---------------------------------------------------------
# Key bindings — focus (arrows + vim keys)
# ---------------------------------------------------------
bindsym \$mod+Left focus left
bindsym \$mod+Down focus down
bindsym \$mod+Up focus up
bindsym \$mod+Right focus right
bindsym \$mod+h focus left
bindsym \$mod+j focus down
bindsym \$mod+k focus up
bindsym \$mod+l focus right

# ---------------------------------------------------------
# Key bindings — move windows (arrows + vim keys)
# ---------------------------------------------------------
bindsym \$mod+Shift+Left move left
bindsym \$mod+Shift+Down move down
bindsym \$mod+Shift+Up move up
bindsym \$mod+Shift+Right move right
bindsym \$mod+Shift+h move left
bindsym \$mod+Shift+j move down
bindsym \$mod+Shift+k move up
bindsym \$mod+Shift+l move right

# ---------------------------------------------------------
# Key bindings — workspaces
# ---------------------------------------------------------
bindsym \$mod+1 workspace number 1
bindsym \$mod+2 workspace number 2
bindsym \$mod+3 workspace number 3
bindsym \$mod+4 workspace number 4
bindsym \$mod+5 workspace number 5

bindsym \$mod+Shift+1 move container to workspace number 1
bindsym \$mod+Shift+2 move container to workspace number 2
bindsym \$mod+Shift+3 move container to workspace number 3
bindsym \$mod+Shift+4 move container to workspace number 4
bindsym \$mod+Shift+5 move container to workspace number 5

# ---------------------------------------------------------
# Key bindings — layout
# ---------------------------------------------------------
bindsym \$mod+b splith
bindsym \$mod+n splitv
bindsym \$mod+s layout stacking
bindsym \$mod+w layout tabbed
bindsym \$mod+e layout toggle split
bindsym \$mod+a focus parent

# ---------------------------------------------------------
# Key bindings — scratchpad
# ---------------------------------------------------------
bindsym \$mod+Shift+minus move scratchpad
bindsym \$mod+minus scratchpad show

# ---------------------------------------------------------
# Key bindings — resize mode
# ---------------------------------------------------------
mode "resize" {
    bindsym Left resize shrink width 10px
    bindsym Down resize grow height 10px
    bindsym Up resize shrink height 10px
    bindsym Right resize grow width 10px
    bindsym h resize shrink width 10px
    bindsym j resize grow height 10px
    bindsym k resize shrink height 10px
    bindsym l resize grow width 10px

    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym \$mod+r mode "resize"

# ---------------------------------------------------------
# Key bindings — Noctalia IPC
# ---------------------------------------------------------
bindsym \$mod+space exec \$ipc launcher toggle
bindsym \$mod+Shift+s exec \$ipc controlCenter toggle
bindsym \$mod+comma exec \$ipc settings toggle

# ---------------------------------------------------------
# Key bindings — media / hardware keys
# ---------------------------------------------------------
bindsym --locked XF86AudioRaiseVolume exec \$ipc volume increase
bindsym --locked XF86AudioLowerVolume exec \$ipc volume decrease
bindsym --locked XF86AudioMute exec \$ipc volume muteOutput
bindsym --locked XF86MonBrightnessUp exec \$ipc brightness increase
bindsym --locked XF86MonBrightnessDown exec \$ipc brightness decrease

bindsym --locked XF86AudioPlay exec playerctl play-pause
bindsym --locked XF86AudioNext exec playerctl next
bindsym --locked XF86AudioPrev exec playerctl previous

# Screenshot (requires grim + slurp)
bindsym Print exec grim
bindsym \$mod+Shift+Print exec grim -g "\$(slurp)"

# ---------------------------------------------------------
# Window rules
# ---------------------------------------------------------
for_window [window_role="dialog"] floating enable
for_window [window_role="pop-up"] floating enable
for_window [window_type="dialog"] floating enable
for_window [app_id="konsole"] opacity 0.95
SWAYEOF
            ;;
    esac

    # Also configure for the created user (if already exists)
    if [[ -n "${USERNAME:-}" ]] && id "${USERNAME}" &>/dev/null; then
        local user_home
        user_home=$(getent passwd "${USERNAME}" | cut -d: -f6)

        # Create Noctalia config dir with correct ownership
        mkdir -p "${user_home}/.config/noctalia/plugins"
        chown -R "${USERNAME}:${USERNAME}" "${user_home}/.config/noctalia"

        case "${compositor}" in
            Hyprland)
                mkdir -p "${user_home}/.config/hypr"
                cp "${skel}/.config/hypr/hyprland.conf" "${user_home}/.config/hypr/" 2>/dev/null || true
                chown -R "${USERNAME}:${USERNAME}" "${user_home}/.config/hypr"
                ;;
            niri)
                mkdir -p "${user_home}/.config/niri"
                cp "${skel}/.config/niri/config.kdl" "${user_home}/.config/niri/" 2>/dev/null || true
                chown -R "${USERNAME}:${USERNAME}" "${user_home}/.config/niri"
                ;;
            sway)
                mkdir -p "${user_home}/.config/sway"
                cp "${skel}/.config/sway/config" "${user_home}/.config/sway/" 2>/dev/null || true
                chown -R "${USERNAME}:${USERNAME}" "${user_home}/.config/sway"
                mkdir -p "${user_home}/.config/environment.d"
                cp "${skel}/.config/environment.d/sway.conf" "${user_home}/.config/environment.d/" 2>/dev/null || true
                chown -R "${USERNAME}:${USERNAME}" "${user_home}/.config/environment.d"
                ;;
        esac
    fi

    einfo "Noctalia Shell configured to autostart with ${compositor}"
}

# _install_printing — Install printing support (CUPS)
_install_printing() {
    einfo "Installing printing support..."
    try "Installing CUPS" xbps-install -y cups cups-filters
    _enable_service "cupsd"
    einfo "Printing support installed"
}

# _noctalia_write_manual_note — Leave instructions when the shell itself could
# not be installed from a repository.
_noctalia_write_manual_note() {
    cat > /root/POST-INSTALL-NOCTALIA.txt << 'EOF'
Noctalia Shell — manual step required
=====================================

The compositor and quickshell (Noctalia's runtime) are installed, but the
shell has no Void package. Install it from upstream:

  git clone https://github.com/noctalia-dev/noctalia-shell ~/.config/quickshell/noctalia-shell
  qs -c noctalia-shell

The compositor configs written by the installer already autostart
`qs -c noctalia-shell`, so it will come up once the files are in place.
EOF
    einfo "  Manual instructions written to /root/POST-INSTALL-NOCTALIA.txt"
}

# install_niri_ecosystem — niri as a standalone session.
#
# Deliberately a thin base layer: niri plus the pieces a scrollable-tiling
# session cannot work without (Xwayland bridge, launcher, bar, notifications,
# lock/idle, screenshots, clipboard, backlight). Everything here comes from
# official Void repos — note `Waybar` with a capital W. Theming and dotfiles
# are left to the user's own config repo rather than duplicated here.
install_niri_ecosystem() {
    if [[ "${ENABLE_NIRI:-no}" != "yes" ]]; then
        return 0
    fi

    einfo "Installing niri ecosystem..."

    try "Installing niri" xbps-install -y niri

    # xwayland-satellite is what makes X11-only applications work under niri;
    # niri has no built-in Xwayland.
    local -a niri_pkgs=(
        xwayland-satellite
        fuzzel Waybar mako
        swaylock swayidle swaybg
        grim slurp wl-clipboard brightnessctl
        xdg-desktop-portal-gtk
    )

    local pkg
    for pkg in "${niri_pkgs[@]}"; do
        xbps-install -y "${pkg}" 2>/dev/null || ewarn "Package '${pkg}' not available, skipping"
    done

    _niri_write_default_config
    _niri_write_portal_config

    einfo "niri ecosystem installed"
}

# _niri_write_portal_config — niri is smithay-based, not wlroots, and the
# default portal chain silently drops FileChooser: "Open file/folder" dialogs
# in GTK/Electron apps then never appear at all (no error, no window). Pin the
# implementations that do work. Same override as the dotfiles repo ships.
_niri_write_portal_config() {
    mkdir -p /etc/xdg-desktop-portal
    cat > /etc/xdg-desktop-portal/niri-portals.conf << 'EOF'
[preferred]
default=gnome;gtk
org.freedesktop.impl.portal.FileChooser=gtk
org.freedesktop.impl.portal.Access=gtk
org.freedesktop.impl.portal.Notification=gtk
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF
    einfo "  niri portal overrides written (/etc/xdg-desktop-portal/niri-portals.conf)"
}

# _niri_write_default_config — Minimal working config in /etc/skel.
# Only what a first login needs: a terminal, a launcher, Xwayland, and a
# HiDPI-friendly scale on Apple Retina panels.
_niri_write_default_config() {
    local skel="/etc/skel/.config/niri"
    mkdir -p "${skel}"

    # Retina MacBook panels are unusable at scale 1; 1.5 is the sane default
    # (2.0 leaves too little logical space on a 12" 2304x1440 screen).
    local scale="1.0"
    if [[ "${APPLE_DETECTED:-0}" == "1" ]]; then
        scale="1.5"
    fi

    local kb_layout="${KEYMAP:-us}"

    cat > "${skel}/config.kdl" << EOF
// niri config — generated by ${INSTALLER_NAME:-void-installer}
// Reference: https://yalter.github.io/niri/

input {
    keyboard {
        xkb {
            layout "${kb_layout}"
        }
    }
    touchpad {
        tap
        natural-scroll
    }
}

output "eDP-1" {
    scale ${scale}
}

spawn-at-startup "xwayland-satellite"
spawn-at-startup "waybar"
spawn-at-startup "mako"

environment {
    DISPLAY ":0"
    QT_QPA_PLATFORM "wayland"
    MOZ_ENABLE_WAYLAND "1"
}

binds {
    Mod+Return { spawn "kitty"; }
    Mod+D { spawn "fuzzel"; }
    Mod+Q { close-window; }
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Down { focus-window-down; }
    Mod+Up { focus-window-up; }
    Mod+Shift+Left { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+Shift+E { quit; }
    Mod+Shift+S { screenshot; }
    Mod+L { spawn "swaylock"; }

    XF86MonBrightnessUp { spawn "brightnessctl" "set" "5%+"; }
    XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }
}
EOF

    # Copy into an already-created user account as well
    if [[ -n "${USERNAME:-}" ]]; then
        local user_home
        user_home=$(getent passwd "${USERNAME}" 2>/dev/null | cut -d: -f6) || true
        if [[ -n "${user_home}" && -d "${user_home}" ]]; then
            mkdir -p "${user_home}/.config/niri"
            cp "${skel}/config.kdl" "${user_home}/.config/niri/" 2>/dev/null || true
            chown -R "${USERNAME}:${USERNAME}" "${user_home}/.config/niri" 2>/dev/null || true
        fi
    fi

    einfo "  niri config written to /etc/skel/.config/niri/config.kdl (scale ${scale})"
}

# _greetd_session_command — Map a session name to the command that starts it.
# gnome-session needs its wrapper; standalone compositors are their own binary
# (niri ships niri-session, which sets up the D-Bus/systemd-less environment).
_greetd_session_command() {
    case "${1:-}" in
        gnome-wayland|gnome) echo "gnome-session" ;;
        niri)                echo "niri-session" ;;
        sway)                echo "sway" ;;
        plasma|kde)          echo "startplasma-wayland" ;;
        *)                   echo "${1:-gnome-session}" ;;
    esac
}

# _configure_greetd — Point greetd at tuigreet and the chosen Wayland session.
# Args: default session command (e.g. "gnome-wayland", "niri", "sway")
#
# greetd is the Wayland-only alternative to GDM/SDDM: it has no X dependency
# at all, runs the greeter on a plain TTY, and execs the session directly.
# tuigreet is the text UI on top of it (both are in the official Void repo).
_configure_greetd() {
    local session="${1:-gnome-wayland}"

    local session_cmd
    session_cmd=$(_greetd_session_command "${session}")

    mkdir -p /etc/greetd

    # --remember keeps the last user; --time shows a clock. The session list
    # is read from /usr/share/wayland-sessions, so anything else the user
    # installs later (niri, sway) shows up without touching this file.
    cat > /etc/greetd/config.toml << GREETDCONF
# greetd — written by ${INSTALLER_NAME:-void-installer}
# Wayland-only session management: no X server anywhere in the chain.

[terminal]
vt = 7

[default_session]
command = "tuigreet --time --remember --sessions /usr/share/wayland-sessions --cmd ${session_cmd}"
user = "_greeter"
GREETDCONF

    chmod 644 /etc/greetd/config.toml

    einfo "  greetd configured (tuigreet, default session: ${session_cmd})"
}

# verify_wayland_only — Report whether xorg-server actually stayed off the
# system. A package chosen on the extras screen can still pull it in, and a
# silent "Wayland-only" that shipped Xorg anyway would be a lie.
verify_wayland_only() {
    [[ "${WAYLAND_ONLY:-no}" == "yes" ]] || return 0

    if xbps-query xorg-server &>/dev/null; then
        ewarn "Wayland-only was requested, but xorg-server IS installed."
        ewarn "Something pulled it in as a dependency. Find out what with:"
        ewarn "  xbps-query -X xorg-server"
        _wayland_only_note "installed"
    else
        einfo "Wayland-only verified: xorg-server is not installed"
        _wayland_only_note "clean"
    fi
}

# _wayland_only_note — Post-install notes for the Wayland-only setup.
_wayland_only_note() {
    local state="$1"
    local note="/root/POST-INSTALL-WAYLAND.txt"

    {
        echo "Wayland-only installation"
        echo "========================="
        echo ""
        if [[ "${state}" == "clean" ]]; then
            echo "xorg-server is NOT installed. X11 applications still run,"
            echo "through Xwayland (xorg-server-xwayland)."
        else
            echo "NOTE: xorg-server ended up installed after all — some package"
            echo "pulled it in. Check with:  xbps-query -X xorg-server"
        fi
        echo ""
        if [[ "${DESKTOP_TYPE:-kde}" == "gnome" ]]; then
            cat << 'EOF'
Login manager: greetd + tuigreet (GDM is not used).
GDM in Void depends on the full xorg-server, which is why it was replaced.

  Config:   /etc/greetd/config.toml
  Service:  ln -sf /etc/sv/greetd /var/service/greetd

To go back to GDM later:
  xbps-install -y gdm            # this also installs xorg-server
  rm /var/service/greetd
  ln -sf /etc/sv/gdm /var/service/gdm
EOF
        else
            cat << 'EOF'
Login manager: SDDM with a Wayland greeter (kwin_wayland as compositor).

  Config:   /etc/sddm.conf.d/10-wayland.conf

If the greeter fails to start, delete that file and reboot — SDDM falls
back to X11, but you then need the full xorg-server:
  xbps-install -y xorg-minimal
EOF
        fi
    } > "${note}"

    einfo "  Notes written to ${note}"
}

# configure_flatpak — Add the Flathub remote and wire up the desktop bits.
#
# Installing the `flatpak` package alone leaves a system where `flatpak
# install` fails with "no remote refs found": there is no configured
# repository, and nothing in the installer used to add one. Two more pieces
# are needed for installed apps to behave like native ones:
#   - a portal implementation, or file dialogs and screen sharing inside the
#     sandbox silently do nothing
#   - /var/lib/flatpak/exports/share on XDG_DATA_DIRS, or the apps install
#     fine and then never appear in the menu
configure_flatpak() {
    # Only when the user actually asked for flatpak on the extras screen
    [[ "${EXTRA_PACKAGES:-}" == *flatpak* ]] || return 0

    einfo "Configuring Flatpak..."

    if ! command -v flatpak >/dev/null 2>&1; then
        ewarn "flatpak is not installed — skipping Flathub setup"
        return 0
    fi

    # A portal is what lets sandboxed apps open files and share the screen.
    # GNOME has its own; everything else gets the GTK one.
    local portal="xdg-desktop-portal-gtk"
    [[ "${DESKTOP_TYPE:-kde}" == "gnome" ]] && portal="xdg-desktop-portal-gnome"
    [[ "${DESKTOP_TYPE:-kde}" == "kde" ]] && portal="xdg-desktop-portal-kde"

    xbps-install -y xdg-desktop-portal "${portal}" 2>/dev/null \
        || ewarn "Could not install ${portal} — file dialogs in flatpaks may not work"

    # remote-add fetches the .flatpakrepo (which carries the GPG key), so it
    # needs network. Failure here is not fatal: the user can rerun the same
    # command later, and it is written into the notes below.
    if flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null; then
        einfo "  Flathub remote added"
    else
        ewarn "Could not add the Flathub remote (no network?) — see /root/POST-INSTALL-FLATPAK.txt"
    fi

    _flatpak_write_profile
    _flatpak_write_note

    einfo "Flatpak configured"
}

# _flatpak_write_profile — Put flatpak exports on XDG_DATA_DIRS.
# Without this, installed flatpaks never show up in the application menu:
# their .desktop files live under /var/lib/flatpak/exports/share, which the
# default XDG_DATA_DIRS does not include.
_flatpak_write_profile() {
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/flatpak.sh << 'EOF'
# Flatpak exports on XDG_DATA_DIRS — written by the Void installer.
# Without this, installed flatpaks do not appear in the application menu.
case ":${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:" in
    *":/var/lib/flatpak/exports/share:"*) ;;
    *) export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share" ;;
esac
EOF
    chmod 644 /etc/profile.d/flatpak.sh
    einfo "  XDG_DATA_DIRS extended for flatpak exports"
}

# _flatpak_write_note — What to do if the remote could not be added.
_flatpak_write_note() {
    cat > /root/POST-INSTALL-FLATPAK.txt << 'EOF'
Flatpak
=======

Flathub remote (rerun if it could not be added during install — it needs
network):

  flatpak remote-add --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo

Then:

  flatpak search <name>
  flatpak install flathub <app-id>
  flatpak update

Notes
-----
- Applications appear in the menu because /etc/profile.d/flatpak.sh puts
  /var/lib/flatpak/exports/share on XDG_DATA_DIRS. Log out and back in after
  the first install if an entry is missing.
- A portal (xdg-desktop-portal + the one matching your desktop) is installed:
  without it, file dialogs and screen sharing inside a sandboxed app fail
  silently.
- Per-user installs: flatpak install --user flathub <app-id>
EOF
    einfo "  Notes written to /root/POST-INSTALL-FLATPAK.txt"
}
