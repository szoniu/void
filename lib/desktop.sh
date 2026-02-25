#!/usr/bin/env bash
# desktop.sh — Desktop environment installation for Void Linux
source "${LIB_DIR}/protection.sh"

# desktop_install — Install full KDE Plasma desktop
desktop_install() {
    einfo "=== Desktop Installation ==="

    _install_gpu_drivers
    _install_kde_plasma
    _install_kde_apps

    einfo "=== Desktop installation complete ==="
}

# _install_gpu_drivers — Install GPU-specific drivers
_install_gpu_drivers() {
    local gpu="${GPU_VENDOR:-}"

    case "${gpu}" in
        nvidia)
            _install_nvidia_drivers
            ;;
        amd)
            _install_amd_drivers
            ;;
        intel)
            _install_intel_drivers
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

    try "Installing NVIDIA drivers" xbps-install -y nvidia

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

    # Core KDE Plasma
    try "Installing KDE Plasma" xbps-install -y \
        kde5 \
        kde5-baseapps \
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

    # PipeWire autostart config
    mkdir -p /etc/pipewire
    if [[ -f /usr/share/pipewire/pipewire.conf ]]; then
        cp /usr/share/pipewire/pipewire.conf /etc/pipewire/
    fi

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
    local app
    for app in ${cleaned}; do
        case "${app}" in
            firefox)       try "Installing ${app}" xbps-install -y firefox ;;
            thunderbird)   try "Installing ${app}" xbps-install -y thunderbird ;;
            libreoffice)   try "Installing ${app}" xbps-install -y libreoffice ;;
            vlc)           try "Installing ${app}" xbps-install -y vlc ;;
            gimp)          try "Installing ${app}" xbps-install -y gimp ;;
            inkscape)      try "Installing ${app}" xbps-install -y inkscape ;;
            krita)         try "Installing ${app}" xbps-install -y krita ;;
            kdenlive)      try "Installing ${app}" xbps-install -y kdenlive ;;
            obs-studio)    try "Installing ${app}" xbps-install -y obs ;;
            vscode)        try "Installing ${app}" xbps-install -y vscode ;;
            *)             try "Installing ${app}" xbps-install -y "${app}" ;;
        esac
    done

    einfo "KDE applications installed"
}
