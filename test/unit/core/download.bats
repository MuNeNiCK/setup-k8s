#!/usr/bin/env bats
# Checksum-verified downloads (lib/core/download.sh) with a fake curl that
# serves files from a local directory.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    SERVE="$BATS_TEST_TMPDIR/serve"
    mkdir -p "$SERVE"
    printf 'payload\n' > "$SERVE/tool"
    cat > "$FAKE_BIN/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        http*) url="\$1" ;;
    esac
    shift
done
f="$SERVE/\${url##*/}"
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
    chmod +x "$FAKE_BIN/curl"
    DEST="$BATS_TEST_TMPDIR/out"
}

@test "download succeeds when the checksum matches" {
    echo "$(sha256sum "$SERVE/tool" | awk '{print $1}')  tool" > "$SERVE/tool.sha256"
    _download_with_checksum https://example.invalid/tool "$DEST" https://example.invalid/tool.sha256
    cmp "$SERVE/tool" "$DEST"
}

@test "download fails and removes the file on checksum mismatch" {
    echo "0000000000000000000000000000000000000000000000000000000000000000  tool" > "$SERVE/tool.sha256"
    run _download_with_checksum https://example.invalid/tool "$DEST" https://example.invalid/tool.sha256
    [ "$status" -ne 0 ]
    [ ! -e "$DEST" ]
}

@test "download fails when the checksum cannot be fetched" {
    run _download_with_checksum https://example.invalid/tool "$DEST" https://example.invalid/missing.sha256
    [ "$status" -ne 0 ]
    [ ! -e "$DEST" ]
}
