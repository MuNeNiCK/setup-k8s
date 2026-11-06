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

# Download a file and verify it against a published sha256 checksum file.
# Without <filename>, the first field of the first line is the checksum (one
# file per checksum file). With <filename>, the line naming that file is used
# (checksum lists such as checksums.txt or *.sha256sum with many entries).
# Fails, and removes the download, when the checksum cannot be fetched or
# does not match.
# Usage: _download_with_checksum <url> <dest> <checksum_url> [filename]
_download_with_checksum() {
    local url="$1" dest="$2" checksum_url="$3" filename="${4:-}" sums expected actual
    _download_binary "$url" "$dest" || return 1
    if ! sums=$(curl -fsSL --retry 3 --retry-delay 2 "$checksum_url"); then
        log_error "Failed to download checksum: $checksum_url"
        rm -f "$dest"
        return 1
    fi
    if [ -n "$filename" ]; then
        expected=$(printf '%s\n' "$sums" | awk -v f="$filename" '$2 == f || $2 == "*"f {print $1; exit}')
    else
        expected=$(printf '%s\n' "$sums" | awk 'NR == 1 {print $1}')
    fi
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        log_error "Checksum mismatch for $(basename "$dest")"
        rm -f "$dest"
        return 1
    fi
    log_info "Checksum verified: $(basename "$dest")"
}
