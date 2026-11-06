#!/bin/sh
# Compare the component versions pinned in lib/core/defaults.sh with the
# latest upstream releases and print a Markdown report.
#
# Usage: scripts/check-versions.sh [report_file]
# Requires: gh (authenticated, e.g. GH_TOKEN in GitHub Actions), jq, sort -V
# Exit status: 0 when every default is current, 1 when an update is
# available, 2 on errors.
#
# containerd follows the patch releases of the pinned minor version (a newer
# minor is reported separately); the other components follow their latest
# release.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFAULTS="$ROOT/lib/core/defaults.sh"
REPORT="${1:-}"

# Value of NAME="${NAME:-value}" in defaults.sh, without a leading "v".
default_of() {
    sed -n "s/^$1=\"\${$1:-v\{0,1\}\([^}]*\)}\".*/\1/p" "$DEFAULTS"
}

# Release tags of a repository (newest first), excluding drafts and prereleases.
release_tags() {
    gh api --paginate "repos/$1/releases?per_page=100" \
        --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name'
}

# Highest version among stdin lines (prefix stripped by the caller).
highest() {
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1
}

outdated=0
rows=""

# Usage: compare <name> <default> <latest> [note]
compare() {
    local status="current"
    if [ -z "$3" ]; then
        echo "error: could not determine the latest $1 release" >&2
        exit 2
    fi
    if [ "$2" != "$3" ]; then
        status="**update available**"
        outdated=1
    fi
    rows="${rows}| $1 | $2 | $3 | ${status} | ${4:-} |
"
}

containerd_default=$(default_of CONTAINERD_VERSION)
containerd_minor="${containerd_default%.*}"
containerd_tags=$(release_tags containerd/containerd | sed 's/^v//')
containerd_patch=$(printf '%s\n' "$containerd_tags" | grep -F "${containerd_minor}." | highest)
containerd_newest=$(printf '%s\n' "$containerd_tags" | highest)
note="latest patch of ${containerd_minor}"
[ "$containerd_newest" != "$containerd_patch" ] && note="${note}; newest release: ${containerd_newest}"
compare containerd "$containerd_default" "$containerd_patch" "$note"

compare runc "$(default_of RUNC_VERSION)" "$(release_tags opencontainers/runc | sed 's/^v//' | highest)"
compare "CNI plugins" "$(default_of CNI_PLUGINS_VERSION)" "$(release_tags containernetworking/plugins | sed 's/^v//' | highest)"
compare kube-vip "$(default_of KUBE_VIP_VERSION)" "$(release_tags kube-vip/kube-vip | sed 's/^v//' | highest)"
compare Helm "$(default_of HELM_VERSION)" "$(release_tags helm/helm | sed 's/^v//' | highest)"
compare Kustomize "$(default_of KUSTOMIZE_VERSION)" \
    "$(release_tags kubernetes-sigs/kustomize | sed -n 's|^kustomize/v||p' | highest)"

report() {
    echo "| Component | Default | Latest | Status | Notes |"
    echo "|---|---|---|---|---|"
    printf '%s' "$rows"
    echo ""
    echo "Defaults are set in \`lib/core/defaults.sh\`. After updating a default, run the"
    echo "VM scenarios that install it (for example \`generic.sh\` for containerd, runc,"
    echo "and CNI plugins, \`ha.sh\` for kube-vip, \`options.sh\` for Helm and Kustomize)."
}
if [ -n "$REPORT" ]; then
    report > "$REPORT"
else
    report
fi

exit "$outdated"
