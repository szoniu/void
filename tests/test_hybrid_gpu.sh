#!/usr/bin/env bash
# tests/test_hybrid_gpu.sh — GPU detection: iGPU/dGPU classification, hybrid
# setups and driver recommendations (Forgejo #2).
#
# Adapted from the Gentoo installer rather than copied: that version asserts on
# VIDEO_CARDS strings parsed out of make.conf, neither of which exists on Void.
# What matters here is the classification itself — it decides whether a laptop
# gets PRIME/hybrid handling at all, and it was silently wrong for AMD iGPU +
# NVIDIA dGPU machines until the bus-based heuristic was replaced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-hybrid-gpu.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${DATA_DIR}/gpu_database.sh"
source "${LIB_DIR}/hardware.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"; (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"; (( FAIL++ )) || true
    fi
}

# lspci stub — each scenario redefines _LSPCI_OUTPUT
lspci() { printf '%s\n' "${_LSPCI_OUTPUT}"; }

echo "=== NVIDIA generation lookup ==="

assert_eq "Ada (RTX 4090, AD102)" "ada"        "$(nvidia_generation 2684)"
assert_eq "Ada (RTX 4080, AD103)" "ada"        "$(nvidia_generation 2704)"
assert_eq "Ampere (RTX 3080)"     "ampere"     "$(nvidia_generation 2206)"
# Boundary: GA107 is the top of Ampere, AD102 the bottom of Ada
assert_eq "Ampere (GA107, 0x25a0)" "ampere"    "$(nvidia_generation 25a0)"
assert_eq "Blackwell (0x2900)"     "blackwell" "$(nvidia_generation 2900)"
assert_eq "Turing (RTX 2060)"     "turing"     "$(nvidia_generation 1f08)"
assert_eq "Pascal (GTX 1060)"     "pre-turing" "$(nvidia_generation 1c03)"

assert_eq "Turing+ supports the open module"  "0" "$(nvidia_supports_open_kernel 2684 && echo 0 || echo 1)"
assert_eq "Pascal does not"                   "1" "$(nvidia_supports_open_kernel 1c03 && echo 0 || echo 1)"

echo ""
echo "=== Driver recommendations ==="

assert_eq "NVIDIA Ada -> nvidia + open module" "nvidia|yes" "$(get_gpu_recommendation 10de 2684)"
assert_eq "NVIDIA Pascal -> nvidia, no open"   "nvidia|no"  "$(get_gpu_recommendation 10de 1c03)"
assert_eq "AMD -> mesa"                        "mesa-dri|no" "$(get_gpu_recommendation 1002 73df)"
assert_eq "Intel -> mesa"                      "mesa-dri|no" "$(get_gpu_recommendation 8086 46a6)"
assert_eq "Unknown vendor falls back to mesa"  "mesa-dri|no" "$(get_gpu_recommendation ffff 0000)"

assert_eq "Intel + NVIDIA" "mesa-dri + nvidia" "$(get_hybrid_gpu_recommendation intel nvidia)"
assert_eq "AMD + NVIDIA"   "mesa-dri + nvidia" "$(get_hybrid_gpu_recommendation amd nvidia)"
assert_eq "Intel + AMD"    "mesa-dri"          "$(get_hybrid_gpu_recommendation intel amd)"
assert_eq "AMD + AMD"      "mesa-dri"          "$(get_hybrid_gpu_recommendation amd amd)"

echo ""
echo "=== Classification: Intel iGPU + NVIDIA dGPU (the common laptop) ==="

_LSPCI_OUTPUT='00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-P [Iris Xe Graphics] [8086:a7a0]
01:00.0 3D controller [0302]: NVIDIA Corporation AD107M [GeForce RTX 4060 Max-Q] [10de:28e0]'
detect_gpu

assert_eq "hybrid detected"        "yes"    "${HYBRID_GPU}"
assert_eq "iGPU is Intel"          "intel"  "${IGPU_VENDOR}"
assert_eq "dGPU is NVIDIA"         "nvidia" "${DGPU_VENDOR}"
assert_eq "primary vendor is dGPU" "nvidia" "${GPU_VENDOR}"

echo ""
echo "=== Classification: AMD iGPU + NVIDIA dGPU ==="

# The regression this guards: AMD APU iGPUs sit on a high PCI bus (c1:/64:),
# never 00 — that slot belongs to Intel. The old "bus 00 = iGPU" heuristic
# classified this machine as NVIDIA-only and it lost hybrid/PRIME handling.
_LSPCI_OUTPUT='c1:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Rembrandt [Radeon 680M] [1002:1681]
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA106M [GeForce RTX 3060] [10de:2560]'
detect_gpu

assert_eq "hybrid detected despite the high bus" "yes"    "${HYBRID_GPU}"
assert_eq "AMD classified as iGPU"               "amd"    "${IGPU_VENDOR}"
assert_eq "NVIDIA classified as dGPU"            "nvidia" "${DGPU_VENDOR}"

echo ""
echo "=== Classification: Intel iGPU + AMD dGPU ==="

_LSPCI_OUTPUT='00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics 620 [8086:5917]
01:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Baffin [Radeon RX 560] [1002:67ef]'
detect_gpu

assert_eq "hybrid detected"     "yes"   "${HYBRID_GPU}"
assert_eq "Intel is the iGPU"   "intel" "${IGPU_VENDOR}"
assert_eq "AMD is the dGPU"     "amd"   "${DGPU_VENDOR}"

echo ""
echo "=== Classification: two AMD GPUs (Framework 16 shape) ==="

_LSPCI_OUTPUT='64:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Phoenix1 [1002:15bf]
03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 33 [Radeon RX 7700S] [1002:7480]'
detect_gpu

assert_eq "two AMD GPUs count as hybrid" "yes" "${HYBRID_GPU}"
assert_eq "first AMD becomes the iGPU"   "amd" "${IGPU_VENDOR}"
assert_eq "second AMD becomes the dGPU"  "amd" "${DGPU_VENDOR}"

echo ""
echo "=== Classification: single GPU is not hybrid ==="

# The MacBook 12" case: one Intel iGPU, nothing else.
_LSPCI_OUTPUT='00:02.0 VGA compatible controller [0300]: Intel Corporation HD Graphics 615 [8086:591e]'
detect_gpu

assert_eq "not hybrid"            "no"      "${HYBRID_GPU}"
assert_eq "vendor is Intel"       "intel"   "${GPU_VENDOR}"
assert_eq "driver is mesa"        "mesa-dri" "${GPU_DRIVER}"
assert_eq "no iGPU/dGPU split"    ""        "${IGPU_VENDOR}${DGPU_VENDOR}"

_LSPCI_OUTPUT='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU106 [GeForce RTX 2070] [10de:1f02]'
detect_gpu

assert_eq "single NVIDIA is not hybrid" "no"     "${HYBRID_GPU}"
assert_eq "NVIDIA vendor"               "nvidia" "${GPU_VENDOR}"
assert_eq "open module offered on Turing" "yes"  "${GPU_USE_NVIDIA_OPEN}"

echo ""
echo "=== No GPU at all (headless VM) ==="

_LSPCI_OUTPUT=''
detect_gpu

assert_eq "no hybrid" "no" "${HYBRID_GPU}"
assert_eq "vendor is unknown or empty" "1" "$( [[ -z "${GPU_VENDOR}" || "${GPU_VENDOR}" == "unknown" ]] && echo 1 || echo 0 )"

unset -f lspci

echo ""
echo "=== Config plumbing ==="

for var in HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME \
           GPU_VENDOR GPU_DRIVER GPU_USE_NVIDIA_OPEN ASUS_ROG_DETECTED ENABLE_ASUSCTL; do
    found=0
    for known in "${CONFIG_VARS[@]}"; do
        [[ "${known}" == "${var}" ]] && found=1 && break
    done
    assert_eq "${var} in CONFIG_VARS" "1" "${found}"
done

rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
