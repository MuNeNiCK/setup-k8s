#!/bin/sh
# Report upstream changes that need action in setup-k8s.
#
# Usage: scripts/check-upstream.sh [OUT_DIR]
#
# Each finding is written to OUT_DIR/<key>.md: the first line is "# <title>",
# the rest is the issue body. The key identifies the finding across runs (the
# weekly workflow keeps one issue per key and closes it once the key is no
# longer reported). The keys and titles are always printed.
#
#   kubernetes-minor-X.Y        a newer minor than test/matrices/kubernetes-minors.txt is released
#   kubernetes-prerelease-X.Y   a prerelease of the next minor is available
#   kubernetes-eol-X.Y          a tested minor reaches its end of life within 60 days (or has)
#   component-NAME              a component default in lib/core/defaults.sh is outdated
#   component-containerd-minor  the pinned containerd minor nears its end of life, or a newer LTS minor exists
#   distro-missing-ID           a test image is no longer in the image catalog
#   distro-eol-ID               a tested distribution reaches its end of life within 60 days (or has)
#   distro-new-ID               a newer release of a tested distribution is in the catalog
#
# Uses only sh, curl, git, and POSIX utilities. Exit status: 0 on success
# (with or without findings); 2 when a source cannot be read, in which case
# nothing is written to OUT_DIR (so that no issue is closed by mistake).
# UPSTREAM_TODAY=YYYY-MM-DD overrides the date (tests).

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CATALOG_URL="https://raw.githubusercontent.com/MuNeNiCK/os-iso-catalog/main/data/images.yaml"
WARN_DAYS=60
TODAY="${UPSTREAM_TODAY:-$(date +%Y-%m-%d)}"
OUT_DIR="${1:-}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/findings"

die() {
    echo "error: $*" >&2
    exit 2
}

fetch() {
    curl -fsSL --retry 3 --retry-delay 2 "$1" || die "cannot read $1"
}

# Succeed when the URL answers 200 (readiness checks)
available() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' -L --retry 2 "$1")" = 200 ]
}

# Release versions (MAJOR.MINOR.PATCH, no prereleases) from the tags of a
# GitHub repository. Usage: release_versions <owner/repo> [tag_prefix]
release_versions() {
    local refs
    refs=$(git ls-remote --tags --refs "https://github.com/$1.git") || die "cannot list the tags of $1"
    printf '%s\n' "$refs" | sed -n "s|.*refs/tags/${2:-v}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\$|\1|p"
}

# Highest version among stdin lines
ver_max() {
    awk -F. '!n || $1+0 > a || ($1+0 == a && ($2+0 > b || ($2+0 == b && $3+0 > c))) { a = $1+0; b = $2+0; c = $3+0; v = $0; n = 1 }
             END { if (n) print v }'
}

# Succeed when version $1 is higher than $2 (MAJOR.MINOR[.PATCH])
ver_gt() {
    awk -v x="$1" -v y="$2" 'BEGIN { split(x, a, "."); split(y, b, ".")
        for (i = 1; i <= 3; i++) { if (a[i]+0 > b[i]+0) exit 0; if (a[i]+0 < b[i]+0) exit 1 }
        exit 1 }'
}

minor_of() { echo "$1" | sed 's/^v//' | cut -d. -f1,2; }

# Days from TODAY to a YYYY-MM-DD date (negative when past)
days_until() {
    awk -v d="$1" -v t="$TODAY" '
        function day(s,   p, y, m) { split(s, p, "-"); y = p[1]; m = p[2] + 0
            if (m <= 2) { y--; m += 12 }
            return int(365.25 * y) - int(y / 100) + int(y / 400) + int(30.6001 * (m + 1)) + p[3] }
        BEGIN { print day(d) - day(t) }'
}

# Usage: finding <key> <title> (body on stdin)
finding() {
    { printf '# %s\n\n' "$2"; cat; } > "$WORK/findings/$1.md"
}

# Value of NAME="${NAME:-value}" in lib/core/defaults.sh, without a leading "v"
default_of() {
    local value
    value=$(sed -n "s/^$1=\"\${$1:-v\{0,1\}\([^}]*\)}\".*/\1/p" "$ROOT/lib/core/defaults.sh")
    [ -n "$value" ] || die "$1 not found in lib/core/defaults.sh"
    echo "$value"
}

# Entries of a list file (comments and blank lines removed)
list_file() {
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$ROOT/$1"
}

yes_no() { if "$@"; then echo yes; else echo "**not yet**"; fi; }

# Succeed when cri-tools has a release of minor $1
has_cri_tools() { printf '%s\n' "$CRI_TOOLS" | grep -q "^$1\\."; }

# --- Kubernetes ---

# Usage: k8s_readiness <minor> <stable|prerelease>
k8s_readiness() {
    local m="$1" ch="$2"
    echo "| Check | Available |"
    echo "|---|---|"
    echo "| pkgs.k8s.io ${ch} deb repository | $(yes_no available "https://pkgs.k8s.io/core:/${ch}:/v${m}/deb/Release") |"
    echo "| pkgs.k8s.io ${ch} rpm repository | $(yes_no available "https://pkgs.k8s.io/core:/${ch}:/v${m}/rpm/repodata/repomd.xml") |"
    echo "| CRI-O ${ch} repository (isv:cri-o) | $(yes_no available "https://download.opensuse.org/repositories/isv:/cri-o:/${ch}:/v${m}/deb/Release") |"
    echo "| CRI-O release tarball | $(yes_no available "https://storage.googleapis.com/cri-o/latest-${m}.txt") |"
    echo "| cri-tools v${m} release | $(yes_no has_cri_tools "$m") |"
}

check_kubernetes() {
    local tested newest stable latest m info end days when
    tested=$(list_file test/matrices/kubernetes-minors.txt)
    newest=$(printf '%s\n' "$tested" | sed 's/$/.0/' | ver_max | cut -d. -f1,2)
    stable=$(fetch https://dl.k8s.io/release/stable.txt)
    stable=${stable#v}
    latest=$(fetch https://dl.k8s.io/release/latest.txt)
    latest=${latest#v}
    CRI_TOOLS=$(release_versions kubernetes-sigs/cri-tools)

    m=$(minor_of "$stable")
    if ver_gt "$m" "$newest"; then
        finding "kubernetes-minor-$m" "Kubernetes $m is released: add it to the tested versions" <<EOF
Kubernetes v${stable} is the latest stable release; the newest tested minor is ${newest}.

Release notes: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-${m}.md
(read "Urgent Upgrade Notes" and the deprecations).

$(k8s_readiness "$m" stable)

To do:

- [ ] Review \`_K8S_FEATURE_MINIMUMS\` in \`lib/core/k8s_version.sh\` against the release notes
- [ ] Add ${m} to \`test/matrices/kubernetes-minors.txt\`; drop minors past end of life
- [ ] Update the option matrix in \`.github/workflows/setup-option-tests.yml\` and the upgrade scenario defaults
- [ ] Run the VM matrices (distro, option, scenario tests); update the documentation and CHANGELOG
EOF
    fi

    m=$(minor_of "$latest")
    case "$latest" in
        *-*)
            if ver_gt "$m" "$(minor_of "$stable")" && ver_gt "$m" "$newest"; then
                finding "kubernetes-prerelease-$m" "Kubernetes $m prerelease is available (v${latest})" <<EOF
The next minor is in prerelease: v${latest}. Testing it before the release finds
incompatibilities early.

$(k8s_readiness "$m" prerelease)

To do:

- [ ] Run \`test/scenarios/init-cleanup.sh --k8s-version ${m} <distro>\` on the main distributions (an unreleased minor installs the prerelease)
- [ ] Check the release notes draft for removals: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-${m}.md
EOF
            fi
            ;;
    esac

    for m in $tested; do
        info=$(fetch "https://endoflife.date/api/kubernetes/${m}.json")
        end=$(printf '%s' "$info" | sed -n 's/.*"eol":"\([0-9-]*\)".*/\1/p')
        [ -n "$end" ] || continue
        days=$(days_until "$end")
        [ "$days" -le "$WARN_DAYS" ] || continue
        when=reaches
        [ "$days" -le 0 ] && when=reached
        finding "kubernetes-eol-$m" "Kubernetes $m $when end of life on $end: drop it from the tested versions" <<EOF
Kubernetes ${m} ${when} end of life on ${end}. Source: https://endoflife.date/kubernetes

To do:

- [ ] Remove ${m} from \`test/matrices/kubernetes-minors.txt\` and from the option matrix
- [ ] Update the documentation and CHANGELOG
EOF
    done
}

# --- Components ---

# Usage: component_finding <name> <variable> <repo> <current> <latest> <scenarios> [note]
component_finding() {
    local kind=patch key warn=""
    if [ "${5%%.*}" != "${4%%.*}" ]; then
        kind=major
        warn="This is a **major** update: read the release notes for breaking changes before updating."
    elif [ "$(minor_of "$5")" != "$(minor_of "$4")" ]; then
        kind=minor
    fi
    key="component-$(echo "$1" | tr 'A-Z ' 'a-z-')"
    finding "$key" "$1 $5 is available ($kind update from $4)" <<EOF
The default $1 version is $4 (\`$2\` in \`lib/core/defaults.sh\`); the latest release is $5.
${7:-}
${warn}

Release: https://github.com/$3/releases

To do:

- [ ] Update \`$2\` in \`lib/core/defaults.sh\`
- [ ] Run the VM scenarios that install it: $6
- [ ] Add a CHANGELOG entry
EOF
}

check_components() {
    local name var repo prefix scenarios current latest versions eol_date
    # name|variable|repository|tag prefix|scenarios
    while IFS='|' read -r name var repo prefix scenarios; do
        current=$(default_of "$var")
        versions=$(release_versions "$repo" "$prefix")
        latest=$(printf '%s\n' "$versions" | ver_max)
        [ -n "$latest" ] || die "no releases found for $repo"
        if ver_gt "$latest" "$current"; then
            component_finding "$name" "$var" "$repo" "$current" "$latest" "$scenarios"
        fi
    done <<'EOF'
runc|RUNC_VERSION|opencontainers/runc|v|generic.sh, init-cleanup.sh on distributions with binary installs
CNI plugins|CNI_PLUGINS_VERSION|containernetworking/plugins|v|generic.sh
kube-vip|KUBE_VIP_VERSION|kube-vip/kube-vip|v|ha.sh, ha.sh --failover
Helm|HELM_VERSION|helm/helm|v|init-cleanup.sh --setup-args "--install-helm true"
Kustomize|KUSTOMIZE_VERSION|kubernetes-sigs/kustomize|kustomize/v|init-cleanup.sh --setup-args "--install-kustomize true"
EOF

    # containerd: the default follows the patch releases of the pinned minor
    current=$(default_of CONTAINERD_VERSION)
    versions=$(release_versions containerd/containerd)
    latest=$(printf '%s\n' "$versions" | grep "^$(minor_of "$current")\." | ver_max)
    if [ -n "$latest" ] && ver_gt "$latest" "$current"; then
        component_finding containerd CONTAINERD_VERSION containerd/containerd "$current" "$latest" \
            "generic.sh, init-cleanup.sh on distributions without containerd 2 packages" \
            "This is the latest patch release of $(minor_of "$current")."
    fi
    # The pinned minor: follow containerd's support table (RELEASES.md).
    # Report when it nears its end of life, or when a newer LTS minor exists.
    local table minor row status eol newest_lts days
    table=$(fetch https://raw.githubusercontent.com/containerd/containerd/main/RELEASES.md \
        | sed -n 's/^| *\[\([0-9][0-9]*\.[0-9][0-9]*\)\]([^)]*) *| *\([^|]*[^ |]\) *| *[^|]*| *\([^|]*[^ |]\) *|.*/\1|\2|\3/p')
    [ -n "$table" ] || die "cannot read the containerd support table"
    minor=$(minor_of "$current")
    row=$(printf '%s\n' "$table" | awk -F'|' -v m="$minor" '$1 == m')
    status=$(printf '%s' "$row" | cut -d'|' -f2)
    eol=$(printf '%s' "$row" | cut -d'|' -f3)
    newest_lts=$(printf '%s\n' "$table" | awk -F'|' '$2 == "LTS" { print $1 ".0" }' | ver_max | cut -d. -f1,2)
    days=99999
    eol_date=$(printf '%s' "$eol" | sed 's/\*//' | awk '{
        split("January February March April May June July August September October November December", n, " ")
        for (i = 1; i <= 12; i++) if (n[i] == $1) m = i
        d = ($3 == "" ? 1 : $2 + 0); y = ($3 == "" ? $2 : $3)
        if (m) printf "%04d-%02d-%02d", y, m, d }')
    [ -n "$eol_date" ] && days=$(days_until "$eol_date")
    if [ -z "$row" ] || [ "$status" = "End of Life" ] || [ "$days" -le "$WARN_DAYS" ]; then
        finding component-containerd-minor "containerd ${minor} ${status:-is not in the support table}${eol:+ (end of life: ${eol})}: move the default" <<EOF
\`CONTAINERD_VERSION\` follows containerd ${minor} (${current}); containerd lists it as
"${status:-unknown}"${eol:+ with end of life ${eol}}. The newest LTS minor is ${newest_lts:-unknown}.
Support table: https://github.com/containerd/containerd/blob/main/RELEASES.md

To do:

- [ ] Move \`CONTAINERD_VERSION\` to the newest LTS minor (check the Kubernetes compatibility table)
- [ ] Run generic.sh and the distro matrix; add a CHANGELOG entry
EOF
    elif [ -n "$newest_lts" ] && ver_gt "$newest_lts" "$minor"; then
        finding component-containerd-minor "containerd ${newest_lts} LTS is available (the default follows ${minor})" <<EOF
containerd ${newest_lts} is a long-term support release; \`CONTAINERD_VERSION\` follows ${minor} (${current}).
Support table: https://github.com/containerd/containerd/blob/main/RELEASES.md

To do:

- [ ] Move \`CONTAINERD_VERSION\` to ${newest_lts} (check the Kubernetes compatibility table)
- [ ] Run generic.sh and the distro matrix; add a CHANGELOG entry
EOF
    fi
}

# --- Distributions ---

# Catalog images as TSV: id name version release_type status eol_standard eol_extended
catalog_tsv() {
    awk '
        function out() { if (id != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, name, ver, rtype, status, eol, ext }
        function val(s) { sub(/^[^:]*:[ ]*/, "", s); gsub(/^["'\'']|["'\'']$/, "", s); if (s == "null") s = ""; return s }
        /^images:/ { on = 1; next }
        !on { next }
        /^- id:/ { out(); id = val($0); name = ver = rtype = status = eol = ext = ""; ineol = 0; next }
        /^  name:/ { name = val($0); ineol = 0; next }
        /^  version:/ { ver = val($0); ineol = 0; next }
        /^  release_type:/ { rtype = val($0); ineol = 0; next }
        /^  status:/ { status = val($0); ineol = 0; next }
        /^  eol:/ { ineol = 1; next }
        /^    standard:/ { if (ineol) eol = val($0); next }
        /^    extended:/ { if (ineol) ext = val($0); next }
        /^  [a-z_]+:/ { ineol = 0 }
        END { out() }'
}

check_distros() {
    local raw catalog
    raw=$(fetch "$CATALOG_URL")
    catalog=$(printf '%s\n' "$raw" | catalog_tsv)
    [ -n "$catalog" ] || die "no images found in $CATALOG_URL"
    printf '%s\n' "$catalog" > "$WORK/catalog.tsv"
    # "id<TAB>extended" for images whose support ends with the extended date
    # (annotated "# eol: extended" in the matrix), otherwise "id<TAB>"
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$ROOT/test/matrices/distro-cloud-images.txt" \
        | awk '{ printf "%s\t%s\n", $1, ($0 ~ /#[[:space:]]*eol:[[:space:]]*extended/ ? "extended" : "") }' > "$WORK/matrix.txt"

    # Lines: missing ID | eol ID NAME DATE STATUS DAYS | new ID NAME NEWEST
    awk -F'\t' -v warn="$WARN_DAYS" -v today="$TODAY" '
        function day(s,   p, y, m) { split(s, p, "-"); y = p[1]; m = p[2] + 0
            if (m <= 2) { y--; m += 12 }
            return int(365.25 * y) - int(y / 100) + int(y / 400) + int(30.6001 * (m + 1)) + p[3] }
        function gt(x, y,   a, b, i) { split(x, a, "."); split(y, b, ".")
            for (i = 1; i <= 3; i++) { if (a[i]+0 > b[i]+0) return 1; if (a[i]+0 < b[i]+0) return 0 }
            return 0 }
        function stem(id, v,   i) { i = index(id, v); return i ? substr(id, 1, i - 1) "{v}" substr(id, i + length(v)) : "" }
        FNR == NR { tested[$1] = 1; order[++n] = $1; useext[$1] = ($2 == "extended"); next }
        { name[$1] = $2; ver[$1] = $3; rtype[$1] = $4; status[$1] = $5; eol[$1] = $6; ext[$1] = $7; all[++m] = $1 }
        END {
            for (i = 1; i <= n; i++) {
                id = order[i]
                if (!(id in name)) { print "missing\t" id; continue }
                if (useext[id] && ext[id] != "") { eol[id] = ext[id]; if (status[id] == "eol-extended") status[id] = "supported" }
                d = (eol[id] != "") ? day(eol[id]) - day(today) : 99999
                if (status[id] ~ /^eol/ || d <= warn)
                    printf "eol\t%s\t%s\t%s\t%s\t%d\n", id, name[id], (eol[id] != "" ? eol[id] : "-"), status[id], d
                s = (ver[id] != "") ? stem(id, ver[id]) : ""
                if (s != "" && (!(s in newest) || gt(ver[id], newest[s]))) newest[s] = ver[id]
            }
            for (j = 1; j <= m; j++) {
                id = all[j]
                if (id in tested || ver[id] == "" || status[id] != "supported") continue
                if (rtype[id] != "stable" && rtype[id] != "rolling" && rtype[id] != "") continue
                s = stem(id, ver[id])
                if (s in newest && gt(ver[id], newest[s])) printf "new\t%s\t%s\t%s\n", id, name[id], newest[s]
            }
        }' "$WORK/matrix.txt" "$WORK/catalog.tsv" > "$WORK/distros.tsv"

    local tab kind id name date status days when
    tab=$(printf '\t')
    while IFS="$tab" read -r kind id name date status days; do
        case "$kind" in
            missing)
                finding "distro-missing-$id" "Test image $id is no longer in the image catalog" <<EOF
\`$id\` is listed in \`test/matrices/distro-cloud-images.txt\` but not in the image catalog
(${CATALOG_URL}); the distro tests fail for it.

To do:

- [ ] Replace or remove it in the matrix (or restore it in MuNeNiCK/os-iso-catalog)
EOF
                ;;
            eol)
                [ "$date" = - ] && date=""
                when=reaches
                case "$status" in eol*) when=reached ;; esac
                [ "$days" -le 0 ] && when=reached
                finding "distro-eol-$id" "$name $when end of life${date:+ on $date}: drop $id from the tests" <<EOF
\`$id\` ($name) $when end of life${date:+ on $date} (catalog status: $status).

To do:

- [ ] Remove it from \`test/matrices/distro-cloud-images.txt\` and the documented distributions
- [ ] Add a CHANGELOG entry
EOF
                ;;
            new)
                # "date" holds the newest tested version here
                finding "distro-new-$id" "$name is available: add $id to the tests" <<EOF
The image catalog has \`$id\` ($name); the newest tested release of this distribution is $date.

To do:

- [ ] Run \`test/scenarios/init-cleanup.sh $id\` (and generic.sh / swap-reboot.sh where relevant)
- [ ] Add it to \`test/matrices/distro-cloud-images.txt\` and the documented distributions; add a CHANGELOG entry
EOF
                ;;
        esac
    done < "$WORK/distros.tsv"
}

check_kubernetes
check_components
check_distros

found=false
for f in "$WORK"/findings/*.md; do
    [ -e "$f" ] || continue
    found=true
    echo "$(basename "$f" .md): $(head -n 1 "$f" | sed 's/^# //')"
done
[ "$found" = true ] || echo "No upstream changes need action."
if [ -n "$OUT_DIR" ]; then
    mkdir -p "$OUT_DIR"
    for f in "$WORK"/findings/*.md; do
        [ -e "$f" ] && cp "$f" "$OUT_DIR/"
    done
fi
exit 0
