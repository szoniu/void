#!/usr/bin/env bash
# tui/gpu_config.sh — GPU driver configuration
source "${LIB_DIR}/protection.sh"

screen_gpu_config() {
    local vendor="${GPU_VENDOR:-unknown}"
    local device="${GPU_DEVICE_NAME:-Unknown GPU}"

    local info_text=""
    info_text+="Detected GPU: ${device}\n"
    info_text+="Vendor: ${vendor}\n\n"

    case "${vendor}" in
        nvidia)
            info_text+="Recommended: nvidia (proprietary, requires nonfree repo)\n"
            if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
                info_text+="NVIDIA open kernel module: supported (Turing+)\n"
            fi
            ;;
        amd)
            info_text+="Recommended: mesa-dri (AMDGPU, open source)\n"
            ;;
        intel)
            info_text+="Recommended: mesa-dri + intel-media-driver\n"
            ;;
        *)
            info_text+="No specific GPU driver detected.\n"
            info_text+="Using generic mesa drivers.\n"
            ;;
    esac

    # Let user confirm or override
    local choice
    choice=$(dialog_menu "GPU Driver" \
        "auto"    "Use recommended driver (${GPU_DRIVER:-auto})" \
        "nvidia"  "NVIDIA proprietary drivers (requires nonfree repo)" \
        "amdgpu"  "AMD open source (mesa-dri)" \
        "intel"   "Intel open source (mesa-dri)" \
        "none"    "No GPU driver (framebuffer only)") \
        || return "${TUI_BACK}"

    case "${choice}" in
        auto)
            # Keep detected values
            ;;
        nvidia)
            GPU_VENDOR="nvidia"
            GPU_DRIVER="nvidia"
            ENABLE_NONFREE="yes"
            export ENABLE_NONFREE

            # Ask about open kernel module
            if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
                dialog_yesno "NVIDIA Open Kernel" \
                    "Your GPU supports the open-source NVIDIA kernel module.\n\n\
This is recommended for Turing (RTX 20xx) and newer GPUs.\n\n\
Use the open kernel module?" \
                    && GPU_USE_NVIDIA_OPEN="yes" \
                    || GPU_USE_NVIDIA_OPEN="no"
            fi
            ;;
        amdgpu)
            GPU_VENDOR="amd"
            GPU_DRIVER="mesa-dri"
            GPU_USE_NVIDIA_OPEN="no"
            ;;
        intel)
            GPU_VENDOR="intel"
            GPU_DRIVER="mesa-dri"
            GPU_USE_NVIDIA_OPEN="no"
            ;;
        none)
            GPU_VENDOR="none"
            GPU_DRIVER="none"
            GPU_USE_NVIDIA_OPEN="no"
            ;;
    esac

    export GPU_VENDOR GPU_DRIVER GPU_USE_NVIDIA_OPEN

    einfo "GPU driver: ${GPU_DRIVER}"
    return "${TUI_NEXT}"
}
