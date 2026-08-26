#!/usr/bin/env bash
# apple.sh — Detection and quirks for Intel Apple hardware (MacBook/iMac/Mac mini).
#
# Three separate concerns live here:
#
#   1. DMI detection (detect_apple) — sets APPLE_DETECTED/APPLE_MODEL, plus
#      APPLE_SPI_INPUT for machines whose keyboard/touchpad hang off SPI
#      (MacBook8,1 and newer, MacBookPro13,*/14,*) rather than USB.
#   2. macOS partition detection (detect_macos_partitions) — APFS and HFS+ are
#      invisible to the generic os-detection in hardware.sh, which only knows
#      ext4/xfs/btrfs/ntfs. Without this a "wipe the whole disk" run would NOT
#      ask the user to type ERASE, because no OS was found on the disk.
#   3. Runtime quirks (apple_write_early_quirks / apple_apply_quirks) — SPI
#      input modules into initramfs, Broadcom bluetooth firmware, HID options.
#
# Apple firmware notes that drive decisions elsewhere in the installer:
#   - Apple's EFI regularly ignores/drops NVRAM boot entries written by
#     efibootmgr, so bootloader.sh also installs GRUB to the removable path
#     (/EFI/BOOT/BOOTX64.EFI) on Apple hardware.
#   - Intel Macs without a T2 chip have no UEFI Secure Boot, so the MOK/shim
#     screen is skipped (tui/secureboot_config.sh).
#   - APFS cannot be resized from Linux at all — shrinking has to happen in
#     macOS Disk Utility before the installer runs (tui/disk_select.sh).
source "${LIB_DIR}/protection.sh"

# GPT partition type GUIDs used by macOS. Matching on the GUID rather than on
# the filesystem string keeps detection working even when the live ISO's
# libblkid is too old to recognise APFS (support landed in util-linux 2.34).
readonly _APPLE_GPT_APFS="7c3457ef-0000-11aa-aa11-00306543ecac"
readonly _APPLE_GPT_HFS="48465300-0000-11aa-aa11-00306543ecac"
readonly _APPLE_GPT_BOOT="426f6f74-0000-11aa-aa11-00306543ecac"
readonly _APPLE_GPT_RECOVERY="52637672-7900-11aa-aa11-00306543ecac"
readonly _APPLE_GPT_CORESTORAGE="53746f72-6167-11aa-aa11-00306543ecac"

# detect_apple — Detect Apple hardware via DMI.
# Sets APPLE_DETECTED (0/1), APPLE_MODEL (e.g. "MacBook10,1") and
# APPLE_SPI_INPUT (0/1, keyboard+touchpad on SPI instead of USB).
detect_apple() {
    APPLE_DETECTED=0
    APPLE_T2_DETECTED=0
    APPLE_MODEL=""
    APPLE_SPI_INPUT=0

    local sys_vendor="" product_name=""
    if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
        sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) || true
    fi
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || true
    fi

    case "${sys_vendor}" in
        "Apple Inc."|"Apple Computer, Inc.")
            APPLE_DETECTED=1
            APPLE_MODEL="${product_name}"
            einfo "Apple hardware detected: ${product_name:-unknown model}"
            ;;
    esac

    if [[ "${APPLE_DETECTED}" == "1" ]]; then
        # T2 Macs (2018+) expose an Apple-vendor (0x106b) PCI device — the T2
        # bridge. They need the out-of-tree apple-bce module and a t2linux
        # kernel to see the internal SSD and keyboard at all; this installer
        # ships neither, so flag it loudly rather than fail confusingly later.
        if lspci -nn 2>/dev/null | grep -qi '\[106b:'; then
            APPLE_T2_DETECTED=1
            ewarn "Apple T2 chip detected — NOT supported by this installer"
            ewarn "  The internal SSD/keyboard need apple-bce + a t2linux kernel."
            ewarn "  See t2linux.org before continuing."
        fi

        if _apple_has_spi_input; then
            APPLE_SPI_INPUT=1
            einfo "  Keyboard/touchpad on SPI (applespi) — initramfs quirk needed"
        fi
    fi

    export APPLE_DETECTED APPLE_T2_DETECTED APPLE_MODEL APPLE_SPI_INPUT
}

# _apple_has_spi_input — True when this Mac drives keyboard+touchpad over SPI.
# Primary check is the ACPI device the applespi driver binds to (APP000D);
# it is enumerated even when the driver itself never loads. The model list is
# only a fallback for when /sys/bus/acpi is unavailable (e.g. inside tests).
_apple_has_spi_input() {
    local d
    for d in /sys/bus/acpi/devices/APP000D:*; do
        [[ -e "${d}" ]] && return 0
    done

    case "${APPLE_MODEL}" in
        MacBook8,*|MacBook9,*|MacBook10,*) return 0 ;;
        MacBookPro13,*|MacBookPro14,*)     return 0 ;;
    esac

    return 1
}

# detect_macos_partitions — Add macOS partitions to DETECTED_OSES.
# Called from detect_installed_oses() in hardware.sh, so DETECTED_OSES is
# already declared. Sets MACOS_DETECTED=1 when a real macOS data partition
# (not just Recovery) is present.
detect_macos_partitions() {
    MACOS_DETECTED="${MACOS_DETECTED:-0}"

    local line part parttype fstype label
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        # lsblk -P output is KEY="value" pairs; parse with sed rather than
        # eval — a partition label is attacker-controlled data.
        part=$(sed -n 's/.*\bPATH="\([^"]*\)".*/\1/p' <<< "${line}")
        parttype=$(sed -n 's/.*\bPARTTYPE="\([^"]*\)".*/\1/p' <<< "${line}")
        fstype=$(sed -n 's/.*\bFSTYPE="\([^"]*\)".*/\1/p' <<< "${line}")
        [[ -z "${part}" ]] && continue

        label=""
        case "${parttype,,}" in
            "${_APPLE_GPT_APFS}")        label="macOS (APFS container)" ;;
            "${_APPLE_GPT_HFS}")         label="macOS (HFS+)" ;;
            "${_APPLE_GPT_BOOT}")        label="macOS Recovery" ;;
            "${_APPLE_GPT_RECOVERY}")    label="macOS Recovery" ;;
            "${_APPLE_GPT_CORESTORAGE}") label="macOS (Core Storage)" ;;
            *)
                case "${fstype,,}" in
                    apfs)       label="macOS (APFS container)" ;;
                    hfsplus|hfs) label="macOS (HFS+)" ;;
                esac
                ;;
        esac

        [[ -z "${label}" ]] && continue

        DETECTED_OSES["${part}"]="${label}"
        if [[ "${label}" != "macOS Recovery" ]]; then
            MACOS_DETECTED=1
        fi
    done < <(lsblk -Plno PATH,PARTTYPE,FSTYPE 2>/dev/null || true)

    export MACOS_DETECTED
}

# apple_fstype_is_macos — True for filesystems the installer must never touch
# with its shrink helpers. Used by the shrink wizard to give a useful message
# instead of a bare "unsupported filesystem".
apple_fstype_is_macos() {
    case "${1,,}" in
        apfs|hfsplus|hfs) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Chroot-side quirks ---

# apple_write_early_quirks — Write module/dracut/modprobe config.
# MUST run before the initramfs is generated (called from kernel_install),
# because the SPI keyboard is otherwise missing from the initramfs and the
# machine has no usable input at early boot.
apple_write_early_quirks() {
    [[ "${APPLE_DETECTED:-0}" == "1" ]] || return 0

    einfo "Writing Apple hardware quirks (${APPLE_MODEL:-unknown model})..."

    mkdir -p /etc/modules-load.d /etc/modprobe.d /etc/dracut.conf.d

    # applesmc exposes temperatures/fans; harmless on fanless models.
    cat > /etc/modules-load.d/apple.conf << 'EOF'
# Apple hardware — written by the Void installer
applesmc
EOF

    if [[ "${APPLE_SPI_INPUT:-0}" == "1" ]]; then
        # The SPI stack is three modules deep: the LPSS MFD enumerates the SPI
        # controller, spi_pxa2xx_platform drives it, applespi binds APP000D.
        cat >> /etc/modules-load.d/apple.conf << 'EOF'
# Keyboard/touchpad live on SPI on this model (MacBook8,1+, MacBookPro13/14)
intel_lpss_pci
spi_pxa2xx_platform
applespi
EOF

        cat > /etc/dracut.conf.d/10-apple-spi.conf << 'EOF'
# Force the SPI input stack into the initramfs — without it there is no
# keyboard at the early boot prompt (rescue shell, LUKS passphrase).
force_drivers+=" intel_lpss_pci spi_pxa2xx_platform applespi "
EOF

        einfo "  SPI keyboard/touchpad modules forced into initramfs"
    fi

    # fnmode=2 makes F1..F12 the primary function of the top row (media keys
    # need Fn). Both drivers take the option; whichever binds wins.
    cat > /etc/modprobe.d/apple-hid.conf << 'EOF'
# Apple keyboards — written by the Void installer.
# fnmode: 0 = disabled, 1 = media keys first, 2 = F-keys first
options hid_apple fnmode=2
options applespi fnmode=2
# ISO (European) keyboards with a swapped `~` / `<` key: set iso_layout=1
#options applespi iso_layout=1
#options hid_apple iso_layout=1
EOF

    # Broadcom Wi-Fi on Macs occasionally drops out under aggressive roaming
    # or PCIe power management. Left commented: enable only if it misbehaves.
    cat > /etc/modprobe.d/apple-brcmfmac.conf << 'EOF'
# Broadcom Wi-Fi (brcmfmac) on Apple hardware.
# Uncomment if the connection drops or reassociates constantly:
#options brcmfmac roamoff=1
EOF

    einfo "Apple early quirks written"
}

# apple_apply_quirks — Chroot phase: firmware packages + post-install notes.
apple_apply_quirks() {
    [[ "${APPLE_DETECTED:-0}" == "1" ]] || return 0

    einfo "Applying Apple runtime quirks..."

    # Broadcom bluetooth needs a .hcd patch file that linux-firmware cannot
    # ship (Broadcom licensing). Void packages it separately; without it the
    # BCM4350 in 2016-2017 MacBooks shows no bluetooth adapter at all.
    einfo "  Installing Broadcom bluetooth firmware..."
    xbps-install -y broadcom-bt-firmware 2>/dev/null \
        || ewarn "broadcom-bt-firmware not available — bluetooth may not work"

    # Wi-Fi firmware: linux-firmware pulls this in transitively, but make it
    # explicit so a future dependency change cannot silently kill Wi-Fi on a
    # machine that has no ethernet port at all.
    xbps-install -y linux-firmware-network 2>/dev/null \
        || ewarn "linux-firmware-network not available"

    _apple_write_post_install_note

    einfo "Apple quirks applied"
}

# _apple_write_post_install_note — Things the user has to know but the
# installer cannot do for them.
_apple_write_post_install_note() {
    local note="/root/POST-INSTALL-APPLE.txt"

    cat > "${note}" << EOF
Apple hardware notes — ${APPLE_MODEL:-Mac}
==========================================

Booting
-------
GRUB was installed both as EFI/Void/grubx64.efi and to the removable path
EFI/BOOT/BOOTX64.EFI, because Apple firmware often ignores NVRAM boot
entries. If the Mac still boots straight into macOS, hold the Option (Alt)
key at power-on and pick "EFI Boot".

Secure Boot
-----------
Intel Macs without a T2 chip have no UEFI Secure Boot — no MOK enrolment
is needed and the installer skipped it.

Keyboard / touchpad
-------------------
Driven by the in-kernel applespi driver over SPI. Options live in
/etc/modprobe.d/apple-hid.conf (fnmode=2 = F-keys first). For an ISO
(European) layout with a swapped backtick key, uncomment iso_layout=1.
If the touchpad is dead right after boot: rmmod applespi && modprobe applespi

Wi-Fi / Bluetooth (Broadcom)
----------------------------
brcmfmac drives the card; 5 GHz support depends on the firmware revision.
Bluetooth needs broadcom-bt-firmware (installed). If the connection drops,
uncomment roamoff=1 in /etc/modprobe.d/apple-brcmfmac.conf.

Display
-------
Retina panels need scaling. GNOME: enable fractional scaling with
  gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
niri: set "scale 1.5" (or 2.0) on the output in ~/.config/niri/config.kdl

macOS partitions
----------------
APFS cannot be resized from Linux. Any repartitioning of a macOS container
must be done in macOS Disk Utility.
EOF

    if [[ "${APPLE_T2_DETECTED:-0}" == "1" ]]; then
        cat >> "${note}" << 'T2EOF'

*** Apple T2 chip: NOT SUPPORTED by this installer. The internal SSD and
keyboard need the out-of-tree apple-bce module and a t2linux kernel. If the
install got this far it most likely ran on external media. See t2linux.org. ***
T2EOF
    fi

    einfo "  Post-install notes written to ${note}"
}
