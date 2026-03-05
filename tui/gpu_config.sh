#!/usr/bin/env bash
# tui/gpu_config.sh — GPU driver configuration
source "${LIB_DIR}/protection.sh"

screen_gpu_config() {
    local vendor="${GPU_VENDOR:-unknown}"
    local device="${GPU_DEVICE_NAME:-Unknown GPU}"

    local info_text=""

    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        info_text+="Hybrid GPU detected:\n"
        info_text+="  iGPU: ${IGPU_DEVICE_NAME:-unknown} (${IGPU_VENDOR:-unknown})\n"
        info_text+="  dGPU: ${DGPU_DEVICE_NAME:-unknown} (${DGPU_VENDOR:-unknown})\n\n"
        info_text+="PRIME render offload: use environment variables for dGPU\n"
        if [[ "${GPU_USE_NVIDIA_OPEN:-no}" == "yes" ]]; then
            info_text+="NVIDIA open kernel module: supported (Turing+)\n"
        fi
    else
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
                info_text+="Recommended: mesa-dri + intel-video-accel\n"
                ;;
            *)
                info_text+="No specific GPU driver detected.\n"
                info_text+="Using generic mesa drivers.\n"
                ;;
        esac
    fi

    # Let user confirm or override
    local auto_label="Use recommended driver"
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        auto_label="Use hybrid PRIME (${IGPU_VENDOR:-?} + ${DGPU_VENDOR:-?})"
    else
        auto_label="Use recommended driver (${GPU_DRIVER:-auto})"
    fi

    local choice
    choice=$(dialog_menu "GPU Driver" \
        "auto"    "${auto_label}" \
        "nvidia"  "NVIDIA proprietary drivers (requires nonfree repo)" \
        "amdgpu"  "AMD open source (mesa-dri)" \
        "intel"   "Intel open source (mesa-dri)" \
        "none"    "No GPU driver (framebuffer only)") \
        || return "${TUI_BACK}"

    case "${choice}" in
        auto)
            # Keep detected values — including hybrid if detected
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

            if [[ "${HYBRID_GPU:-no}" != "yes" ]]; then
                IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
                DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            fi
            ;;
        amdgpu)
            GPU_VENDOR="amd"
            GPU_DRIVER="mesa-dri"
            GPU_USE_NVIDIA_OPEN="no"
            HYBRID_GPU="no"
            IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
            DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            ;;
        intel)
            GPU_VENDOR="intel"
            GPU_DRIVER="mesa-dri"
            GPU_USE_NVIDIA_OPEN="no"
            HYBRID_GPU="no"
            IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
            DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            ;;
        none)
            GPU_VENDOR="none"
            GPU_DRIVER="none"
            GPU_USE_NVIDIA_OPEN="no"
            HYBRID_GPU="no"
            IGPU_VENDOR="" ; IGPU_DEVICE_NAME=""
            DGPU_VENDOR="" ; DGPU_DEVICE_NAME=""
            ;;
    esac

    export GPU_VENDOR GPU_DRIVER GPU_USE_NVIDIA_OPEN
    export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME

    einfo "GPU driver: ${GPU_DRIVER}"
    [[ "${HYBRID_GPU}" == "yes" ]] && einfo "Hybrid GPU: ${IGPU_VENDOR} + ${DGPU_VENDOR} (PRIME)"
    return "${TUI_NEXT}"
}
