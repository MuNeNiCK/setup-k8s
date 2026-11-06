#!/bin/sh

# State management module: persistent operation state for resume/checkpoint.
# State is stored as a key=value file under /var/lib/setup-k8s/state/.
#
# Usage:
#   _state_init "deploy"              # create a new state file
#   _state_set "key" "value"          # set a key
#   _state_get "key"                  # get a key (empty string if not set)
#   _state_mark_step "step" "done"    # mark step status (pending/running/done/failed)
#   _state_is_step_done "step"        # returns 0 if step is done
#   _state_find_resume "deploy"       # find latest resumable state file
#   _state_load "file"                # load state from file
#   _state_cleanup                    # remove current state file

_STATE_FILE=""
_STATE_DIR="/var/lib/setup-k8s/state"

# Initialize a new state file for the given operation.
_state_init() {
    local operation="$1"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "unknown")
    mkdir -p "$_STATE_DIR"
    _STATE_FILE="${_STATE_DIR}/${operation}-${ts}.state"
    : > "$_STATE_FILE"
    chmod 600 "$_STATE_FILE"
    _state_set "operation" "$operation"
    _state_set "started_at" "$ts"
    _state_set "status" "running"
    log_debug "State file initialized: $_STATE_FILE"
}

# Set a key=value pair in the current state file.
_state_set() {
    local key="$1" value="$2"
    if [ -z "$_STATE_FILE" ]; then
        return 0
    fi
    # Remove existing key (if any) then append new value
    local tmpf
    tmpf=$(mktemp "${_STATE_FILE}.tmp.XXXXXX")
    grep -v "^${key}=" "$_STATE_FILE" > "$tmpf" 2>/dev/null || true
    echo "${key}=${value}" >> "$tmpf"
    mv "$tmpf" "$_STATE_FILE"
}

# Get the value for a key from the current state file.
_state_get() {
    local key="$1"
    if [ -z "$_STATE_FILE" ] || [ ! -f "$_STATE_FILE" ]; then
        echo ""
        return 0
    fi
    local val
    val=$(grep "^${key}=" "$_STATE_FILE" | tail -1 | cut -d= -f2-)
    echo "$val"
}

# Mark a step with a status (pending, running, done, failed).
_state_mark_step() {
    local step="$1" status="$2"
    _state_set "step_${step}" "$status"
}

# Check if a step is done. Returns 0 if done, 1 otherwise.
_state_is_step_done() {
    local step="$1"
    local val
    val=$(_state_get "step_${step}")
    [ "$val" = "done" ]
}

# Find the latest resumable (non-completed) state file for an operation.
# Returns the path, or empty string if none found.
_state_find_resume() {
    local operation="$1"
    local latest=""
    if [ ! -d "$_STATE_DIR" ]; then
        echo ""
        return 0
    fi
    # Find latest state file for this operation that is still running/failed
    for f in "${_STATE_DIR}/${operation}"-*.state; do
        [ -f "$f" ] || continue
        local file_status
        file_status=$(grep "^status=" "$f" | tail -1 | cut -d= -f2-)
        if [ "$file_status" = "running" ] || [ "$file_status" = "failed" ]; then
            latest="$f"
        fi
    done
    echo "$latest"
}

# Load state from a given file.
_state_load() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log_error "State file not found: $file"
        return 1
    fi
    _STATE_FILE="$file"
    log_info "Resumed from state file: $_STATE_FILE"
}

# Mark current state as completed and clean up.
_state_complete() {
    if [ -n "$_STATE_FILE" ] && [ -f "$_STATE_FILE" ]; then
        _state_set "status" "completed"
        _state_set "completed_at" "$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "unknown")"
        log_debug "State marked completed: $_STATE_FILE"
    fi
    _STATE_FILE=""
}

# Remove current state file entirely.
_state_cleanup() {
    if [ -n "$_STATE_FILE" ]; then
        rm -f "$_STATE_FILE"
        _STATE_FILE=""
    fi
}
