#!/bin/sh
# Keep one GitHub issue per finding of scripts/check-upstream.sh.
#
# Usage: scripts/upstream-issues.sh <findings_dir>
#
# Opens an issue (label "upstream") for each new finding, updates the title
# and body of the open issue of a finding that is still reported, and closes
# open issues whose finding is no longer reported. The last line of each
# issue body ("Tracking key: `<key>`") links the issue to its finding.
#
# Requires gh (GitHub CLI) with GH_TOKEN (issues: write); runs in the
# repository checkout or with GH_REPO=owner/repo. DRY_RUN=1 prints the
# changes instead of making them.

set -eu

DIR="${1:?usage: $0 <findings_dir>}"
LABEL=upstream

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Run a gh command that changes something (printed only with DRY_RUN=1)
change() {
    if [ "${DRY_RUN:-0}" = 1 ]; then
        echo "DRY RUN: gh $*" >&2
        return 0
    fi
    gh "$@"
}

if ! gh label list --search "$LABEL" --json name --jq '.[].name' | grep -qx "$LABEL"; then
    change label create "$LABEL" --color d93f0b --description "Upstream change that needs action"
fi

# "number key" of each open issue with the label
existing=$(gh issue list --label "$LABEL" --state open --limit 200 --json number,body \
    --jq '.[] | ((.body // "") | capture("Tracking key: `(?<k>[a-z0-9.-]+)`").k) as $k | "\(.number) \($k)"')

for f in "$DIR"/*.md; do
    [ -e "$f" ] || continue
    key=$(basename "$f" .md)
    title=$(head -n 1 "$f" | sed 's/^# //')
    {
        tail -n +3 "$f"
        printf '\n---\nTracking key: `%s` (managed by the weekly upstream check: updated while reported, closed when resolved)\n' "$key"
    } > "$WORK/body.md"
    number=$(printf '%s\n' "$existing" | awk -v k="$key" '$2 == k { print $1; exit }')
    if [ -n "$number" ]; then
        change issue edit "$number" --title "$title" --body-file "$WORK/body.md" >/dev/null
        echo "updated #${number}: ${title}"
    else
        change issue create --title "$title" --label "$LABEL" --body-file "$WORK/body.md" >/dev/null
        echo "opened: ${title}"
    fi
done

printf '%s\n' "$existing" | while read -r number key; do
    [ -n "${key:-}" ] || continue
    [ -e "$DIR/${key}.md" ] && continue
    change issue close "$number" --reason completed --comment "Resolved: the upstream check no longer reports this."
    echo "closed #${number} (${key})"
done
