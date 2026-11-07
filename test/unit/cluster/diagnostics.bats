#!/usr/bin/env bats
# Diagnostics collection (lib/cluster/diagnostics.sh).

setup() {
    load '../helpers/common'
    load_modules
    quiet_logs
}

@test "local diagnostics save kubelet, containerd, and system information" {
    fake_cmd hostname 0 node1
    fake_cmd journalctl 0 "-- log line --"
    fake_cmd df 0 "/dev/vda1 40G"
    fake_cmd free 0 "Mem: 4096"
    _collect_local_diagnostics "$BATS_TEST_TMPDIR/diag"
    grep -q 'log line' "$BATS_TEST_TMPDIR/diag/node1-kubelet.log"
    grep -q 'log line' "$BATS_TEST_TMPDIR/diag/node1-containerd.log"
    grep -q '/dev/vda1' "$BATS_TEST_TMPDIR/diag/node1-system.log"
    fake_calls | grep -q '^journalctl -u kubelet'
}
