#!/usr/bin/env bash
# rootfs.sh — Download, verify and extract Void Linux ROOTFS
source "${LIB_DIR}/protection.sh"

# ROOTFS_FILE — Path to downloaded ROOTFS tarball (set by rootfs_download)
ROOTFS_FILE=""

# _find_rootfs_file — Find existing ROOTFS tarball on mountpoint (for resume)
_find_rootfs_file() {
    if [[ -n "${ROOTFS_FILE:-}" && -f "${ROOTFS_FILE}" ]]; then
        return 0
    fi
    local f
    for f in "${MOUNTPOINT}"/void-x86_64-ROOTFS-*.tar.xz; do
        if [[ -f "${f}" ]]; then
            ROOTFS_FILE="${f}"
            export ROOTFS_FILE
            einfo "Found ROOTFS tarball: ${f}"
            return 0
        fi
    done
    return 1
}

# rootfs_get_url — Get the latest ROOTFS download URL
# Void publishes ROOTFS at a fixed URL pattern, we need to find the actual filename
rootfs_get_url() {
    local mirror="${MIRROR_URL:-${VOID_REPO_BASE}}"
    local base_url="${mirror}/live/current"

    einfo "Fetching ROOTFS file list from ${base_url}..."

    # Download the sha256sum.txt to find the actual ROOTFS filename
    local sha256_file
    sha256_file=$(mktemp "${TMPDIR:-/tmp}/void-sha256.XXXXXX")

    if ! curl -fsSL -o "${sha256_file}" "${base_url}/sha256sum.txt" 2>>"${LOG_FILE}"; then
        rm -f "${sha256_file}"
        die "Failed to fetch sha256sum.txt from ${base_url}"
    fi

    # Extract the ROOTFS filename (glibc x86_64, not musl)
    local rootfs_name
    rootfs_name=$(sed -n 's/^[a-f0-9]\{64\}  \(void-x86_64-ROOTFS-[0-9]\{8\}\.tar\.xz\)$/\1/p' "${sha256_file}" | head -1) || true
    rm -f "${sha256_file}"

    if [[ -z "${rootfs_name}" ]]; then
        die "Could not find ROOTFS filename in sha256sum.txt"
    fi

    ROOTFS_URL="${base_url}/${rootfs_name}"
    ROOTFS_EXPECTED_NAME="${rootfs_name}"
    export ROOTFS_URL ROOTFS_EXPECTED_NAME

    einfo "ROOTFS: ${rootfs_name}"
    einfo "URL: ${ROOTFS_URL}"
}

# rootfs_download — Download the ROOTFS tarball
rootfs_download() {
    einfo "Downloading ROOTFS tarball..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would download ROOTFS"
        return 0
    fi

    # Check if already downloaded (resume case)
    if _find_rootfs_file; then
        einfo "ROOTFS already downloaded: ${ROOTFS_FILE}"
        return 0
    fi

    rootfs_get_url

    ROOTFS_FILE="${MOUNTPOINT}/${ROOTFS_EXPECTED_NAME}"
    export ROOTFS_FILE

    einfo "Downloading ROOTFS to ${ROOTFS_FILE}..."
    try "Downloading Void ROOTFS" curl -fSL -o "${ROOTFS_FILE}" "${ROOTFS_URL}"

    einfo "ROOTFS downloaded: ${ROOTFS_FILE}"
}

# rootfs_verify — Verify ROOTFS integrity using SHA256
rootfs_verify() {
    einfo "Verifying ROOTFS integrity..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would verify ROOTFS"
        return 0
    fi

    if [[ -z "${ROOTFS_FILE}" ]]; then
        _find_rootfs_file || die "No ROOTFS file found to verify"
    fi

    local mirror="${MIRROR_URL:-${VOID_REPO_BASE}}"
    local sha256_url="${mirror}/live/current/sha256sum.txt"
    local sha256_file
    sha256_file=$(mktemp "${TMPDIR:-/tmp}/void-sha256-verify.XXXXXX")

    einfo "Downloading SHA256 checksums..."
    try "Downloading SHA256 checksums" curl -fsSL -o "${sha256_file}" "${sha256_url}"

    local rootfs_basename
    rootfs_basename=$(basename "${ROOTFS_FILE}")

    # Extract expected hash for our file
    local expected_hash
    expected_hash=$(sed -n "s/^\([a-f0-9]\{64\}\)  ${rootfs_basename}$/\1/p" "${sha256_file}") || true
    rm -f "${sha256_file}"

    if [[ -z "${expected_hash}" ]]; then
        die "Could not find SHA256 hash for ${rootfs_basename} in sha256sum.txt"
    fi

    einfo "Checking SHA256 checksum..."
    local actual_hash
    actual_hash=$(sha256sum "${ROOTFS_FILE}" | cut -d' ' -f1) || true

    if [[ "${actual_hash}" != "${expected_hash}" ]]; then
        eerror "SHA256 mismatch!"
        eerror "Expected: ${expected_hash}"
        eerror "Got:      ${actual_hash}"
        die "ROOTFS verification failed"
    fi

    einfo "SHA256 verification passed"
}

# rootfs_extract — Extract ROOTFS tarball to mountpoint
rootfs_extract() {
    einfo "Extracting ROOTFS tarball..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would extract ROOTFS to ${MOUNTPOINT}"
        return 0
    fi

    if [[ -z "${ROOTFS_FILE}" ]]; then
        _find_rootfs_file || die "No ROOTFS file found to extract"
    fi

    # Check if already extracted (resume case)
    if [[ -f "${MOUNTPOINT}/usr/bin/xbps-install" ]]; then
        einfo "ROOTFS already extracted (xbps-install found)"
        return 0
    fi

    einfo "Extracting ROOTFS to ${MOUNTPOINT}..."
    try "Extracting Void ROOTFS" tar xpf "${ROOTFS_FILE}" -C "${MOUNTPOINT}"

    # Clean up tarball to save space
    rm -f "${ROOTFS_FILE}"

    einfo "ROOTFS extracted successfully"
}
