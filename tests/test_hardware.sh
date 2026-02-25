#!/usr/bin/env bash
# tests/test_hardware.sh — Test GPU database with mock data (no CPU march for Void)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _VOID_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/void-test-hardware.log"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${DATA_DIR}/gpu_database.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"
        (( FAIL++ )) || true
    fi
}

echo "=== Test: NVIDIA GPU Generation Detection ==="

assert_eq "Turing device" "turing" "$(nvidia_generation "1e82")"
assert_eq "Ampere device" "ampere" "$(nvidia_generation "2204")"
assert_eq "Ada device" "ada" "$(nvidia_generation "2704")"
assert_eq "Blackwell device" "blackwell" "$(nvidia_generation "2904")"
assert_eq "Pre-Turing device" "pre-turing" "$(nvidia_generation "1b80")"

echo ""
echo "=== Test: NVIDIA Open Kernel Support ==="

nvidia_supports_open_kernel "2704" && result="yes" || result="no"
assert_eq "Ada supports open kernel" "yes" "${result}"

nvidia_supports_open_kernel "1b80" && result="yes" || result="no"
assert_eq "Pascal doesn't support open kernel" "no" "${result}"

nvidia_prefers_open_kernel "2704" && result="yes" || result="no"
assert_eq "Ada prefers open kernel" "yes" "${result}"

nvidia_prefers_open_kernel "1e82" && result="yes" || result="no"
assert_eq "Turing doesn't prefer open kernel" "no" "${result}"

echo ""
echo "=== Test: GPU Recommendation (Void packages — 2-field output) ==="

# NVIDIA → "nvidia|use_open" (no VIDEO_CARDS in Void)
rec=$(get_gpu_recommendation "10de" "2704")
assert_eq "NVIDIA recommendation" "nvidia|yes" "${rec}"

# AMD → "mesa-dri|no"
rec=$(get_gpu_recommendation "1002" "7340")
assert_eq "AMD recommendation" "mesa-dri|no" "${rec}"

# Intel → "mesa-dri|no"
rec=$(get_gpu_recommendation "8086" "9a49")
assert_eq "Intel recommendation" "mesa-dri|no" "${rec}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
