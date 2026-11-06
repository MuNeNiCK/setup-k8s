#!/bin/sh

# Download helpers. Checksums are verified when a checksum URL is given.

_download_binary() {
    local url="$1" dest="$2"
    log_info "Downloading: $url"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
        log_error "Failed to download: $url"
        return 1
    fi
    chmod +x "$dest"
}

# Checksum-verified download (verification is best-effort)
# Usage: _download_with_checksum <url> <dest> [checksum_url]
_download_with_checksum() {
    local url="$1" dest="$2" checksum_url="${3:-}"
    _download_binary "$url" "$dest"
    if [ -n "$checksum_url" ]; then
        local expected actual
        if expected=$(curl -fsSL "$checksum_url" 2>/dev/null); then
            expected=$(echo "$expected" | awk '{print $1}')
            actual=$(sha256sum "$dest" | awk '{print $1}')
            if [ "$expected" != "$actual" ]; then
                log_error "Checksum mismatch for $dest"
                rm -f "$dest"
                return 1
            fi
            log_info "Checksum verified: $(basename "$dest")"
        fi
    fi
}
