#!/bin/bash
#
# HA test dispatcher: routes to init or failover test based on --failover flag.
# Usage: ./test/scenarios/ha.sh [--failover] [options...]
#

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILOVER=false
for arg in "$@"; do [ "$arg" = "--failover" ] && FAILOVER=true; done

if [ "$FAILOVER" = true ]; then
    exec bash "$SCENARIO_DIR/ha-failover.sh" "$@"
else
    exec bash "$SCENARIO_DIR/ha-init.sh" "$@"
fi
