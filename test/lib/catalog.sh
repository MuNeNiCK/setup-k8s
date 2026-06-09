#!/bin/bash

test_default_matrix_file() {
    printf '%s\n' "${TEST_DISTRO_MATRIX_FILE:-$SCRIPT_DIR/matrices/distro-cloud-images.txt}"
}

test_list_matrix_distros() {
    local matrix_file
    matrix_file=$(test_default_matrix_file)
    if [ ! -f "$matrix_file" ]; then
        log_error "Matrix file not found: $matrix_file"
        return 1
    fi
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$matrix_file"
}

test_validate_runner_distro() {
    local distro=$1
    if [ "${SKIP_RUNNER_DRY_RUN:-0}" = "1" ]; then
        return 0
    fi
    case " ${_RUNNER_VALIDATED_DISTROS:-} " in
        *" $distro "*) return 0 ;;
    esac
    log_info "Validating docker-vm-runner image ID: $distro"
    if docker run --rm -e "DISTRO=$distro" "$DOCKER_VM_RUNNER_IMAGE" --dry-run >/dev/null; then
        _RUNNER_VALIDATED_DISTROS="${_RUNNER_VALIDATED_DISTROS:-} $distro"
        return 0
    fi
    log_error "docker-vm-runner rejected image ID: $distro"
    log_error "Run: docker run --rm $DOCKER_VM_RUNNER_IMAGE --list-distros --type cloud-image"
    return 1
}
