#!/bin/sh

# Download helpers.

_download_binary() {
    local url="$1" dest="$2"
    log_info "Downloading: $url"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
        log_error "Failed to download: $url"
        return 1
    fi
    chmod +x "$dest"
}

# Download a file and verify it against a published sha256 checksum file
# (first field of its first line). Fails, and removes the download, when the
# checksum cannot be fetched or does not match.
# Usage: _download_with_checksum <url> <dest> <checksum_url>
_download_with_checksum() {
    local url="$1" dest="$2" checksum_url="$3" expected actual
    _download_binary "$url" "$dest" || return 1
    if ! expected=$(curl -fsSL --retry 3 --retry-delay 2 "$checksum_url"); then
        log_error "Failed to download checksum: $checksum_url"
        rm -f "$dest"
        return 1
    fi
    expected=$(printf '%s\n' "$expected" | awk 'NR == 1 {print $1}')
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        log_error "Checksum mismatch for $(basename "$dest")"
        rm -f "$dest"
        return 1
    fi
    log_info "Checksum verified: $(basename "$dest")"
}
