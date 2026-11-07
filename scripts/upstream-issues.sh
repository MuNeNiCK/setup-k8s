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
# Environment: GITHUB_TOKEN (issues: write), GITHUB_REPOSITORY (owner/repo).
# DRY_RUN=1 prints the changes instead of making them.
# Uses only sh, curl, and POSIX utilities.

set -eu

DIR="${1:?usage: $0 <findings_dir>}"
API="https://api.github.com/repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
LABEL=upstream
: "${GITHUB_TOKEN:?GITHUB_TOKEN is not set}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Usage: api <method> <path> [json_file]
api() {
    local method="$1" path="$2" data="${3:-}"
    if [ "${DRY_RUN:-0}" = 1 ] && [ "$method" != GET ]; then
        echo "DRY RUN: $method $path" >&2
        if [ -n "$data" ]; then cat "$data" >&2; echo >&2; fi
        return 0
    fi
    if [ -n "$data" ]; then
        _curl -X "$method" --data-binary "@$data" "$API$path"
    else
        _curl -X "$method" "$API$path"
    fi
}

_curl() {
    curl -fsS --retry 3 \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@"
}

# stdin as a JSON string literal
json_str() {
    awk 'BEGIN { ORS = ""; print "\"" }
         { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "")
           if (NR > 1) print "\\n"
           print }
         END { print "\"" }'
}

# "number key" of each open issue with the label (from the API's one field
# per line JSON: issue fields are indented by four spaces)
open_issues() {
    local list
    list=$(api GET "/issues?labels=${LABEL}&state=open&per_page=100") || exit 1
    printf '%s\n' "$list" | awk '
        /^    "number": / { n = $2; sub(/,$/, "", n) }
        /^    "body": / { if (match($0, /Tracking key: `[a-z0-9.-]+`/)) print n, substr($0, RSTART + 15, RLENGTH - 16) }'
}

# The label exists or is created
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${GITHUB_TOKEN}" "$API/labels/${LABEL}")
if [ "$code" = 404 ]; then
    printf '{"name":"%s","color":"d93f0b","description":"Upstream change that needs action"}' "$LABEL" > "$WORK/label.json"
    api POST /labels "$WORK/label.json" >/dev/null
elif [ "$code" != 200 ]; then
    echo "error: cannot read label ${LABEL} (HTTP ${code})" >&2
    exit 1
fi

existing=$(open_issues)

for f in "$DIR"/*.md; do
    [ -e "$f" ] || continue
    key=$(basename "$f" .md)
    title=$(head -n 1 "$f" | sed 's/^# //')
    {
        tail -n +3 "$f"
        printf '\n---\nTracking key: `%s` (managed by the weekly upstream check: updated while reported, closed when resolved)\n' "$key"
    } > "$WORK/body.md"
    number=$(printf '%s\n' "$existing" | awk -v k="$key" '$2 == k { print $1; exit }')
    {
        printf '{"title":'; printf '%s' "$title" | json_str
        printf ',"body":'; json_str < "$WORK/body.md"
        [ -n "$number" ] || printf ',"labels":["%s"]' "$LABEL"
        printf '}'
    } > "$WORK/request.json"
    if [ -n "$number" ]; then
        api PATCH "/issues/${number}" "$WORK/request.json" >/dev/null
        echo "updated #${number}: ${title}"
    else
        api POST /issues "$WORK/request.json" >/dev/null
        echo "opened: ${title}"
    fi
done

printf '%s\n' "$existing" | while read -r number key; do
    [ -n "${key:-}" ] || continue
    [ -e "$DIR/${key}.md" ] && continue
    printf '{"body":"Resolved: the upstream check no longer reports this."}' > "$WORK/comment.json"
    printf '{"state":"closed","state_reason":"completed"}' > "$WORK/close.json"
    api POST "/issues/${number}/comments" "$WORK/comment.json" >/dev/null
    api PATCH "/issues/${number}" "$WORK/close.json" >/dev/null
    echo "closed #${number} (${key})"
done
