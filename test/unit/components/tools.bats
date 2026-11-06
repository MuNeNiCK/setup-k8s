#!/usr/bin/env bats
# shellcheck disable=SC2034 # tests set globals read by the modules under test
# Helm and Kustomize installation from pinned release tarballs
# (lib/components/tools.sh). A fake curl serves locally built tarballs and
# records the requested URLs; install(1) is redirected into the test dir.

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
    SERVE="$BATS_TEST_TMPDIR/serve"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$SERVE" "$BIN"
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
echo "curl \$url" >> "$FAKE_LOG"
f="$SERVE/\${url##*/}"
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
EOF
    chmod +x "$FAKE_BIN/curl"
    cat > "$FAKE_BIN/install" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
for a in "\$@"; do case "\$a" in -*|0755) ;; "\$last") ;; *) src="\$a" ;; esac; done
cp "\$src" "$BIN/\${last##*/}" && chmod 755 "$BIN/\${last##*/}"
EOF
    chmod +x "$FAKE_BIN/install"
    _detect_arch() { echo amd64; }
}

# Build <tarball> containing <member> and publish its sha256 in <sums> as
# "<hash>  <tarball>" (plus an unrelated line).
_publish() {
    local tarball="$1" member="$2" sums="$3" work="$BATS_TEST_TMPDIR/work"
    rm -rf "$work"; mkdir -p "$work/$(dirname "$member")"
    printf '#!/bin/sh\necho tool\n' > "$work/$member"
    tar -czf "$SERVE/$tarball" -C "$work" "$member"
    {
        echo "0000000000000000000000000000000000000000000000000000000000000000  other.tar.gz"
        echo "$(sha256sum "$SERVE/$tarball" | awk '{print $1}')  $tarball"
    } > "$SERVE/$sums"
}

@test "install_helm installs the pinned Helm release after checksum verification" {
    HELM_VERSION=4.3.1
    _publish helm-v4.3.1-linux-amd64.tar.gz linux-amd64/helm helm-v4.3.1-linux-amd64.tar.gz.sha256sum
    install_helm
    [ -x "$BIN/helm" ]
    fake_calls | grep -qx 'curl https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz'
}

@test "install_kustomize installs the pinned release using checksums.txt" {
    KUSTOMIZE_VERSION=5.8.3
    _publish kustomize_v5.8.3_linux_amd64.tar.gz kustomize checksums.txt
    install_kustomize
    [ -x "$BIN/kustomize" ]
    fake_calls | grep -q 'kustomize%2Fv5.8.3/kustomize_v5.8.3_linux_amd64.tar.gz'
}

@test "a tampered tarball is not installed" {
    HELM_VERSION=4.3.1
    _publish helm-v4.3.1-linux-amd64.tar.gz linux-amd64/helm helm-v4.3.1-linux-amd64.tar.gz.sha256sum
    echo tampered >> "$SERVE/helm-v4.3.1-linux-amd64.tar.gz"
    run install_helm
    [ "$status" -ne 0 ]
    [ ! -e "$BIN/helm" ]
}
