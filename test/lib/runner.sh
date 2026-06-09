#!/bin/bash

# shellcheck source=test/lib/vm_harness.sh
source "$SCRIPT_DIR/lib/vm_harness.sh"
# shellcheck source=test/lib/catalog.sh
source "$SCRIPT_DIR/lib/catalog.sh"

test_prepare_runner_dirs() {
    mkdir -p "$VM_DATA_DIR"
}
