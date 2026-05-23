#!/usr/bin/env bash
#
# Turn a ticket-relevant change into a GitHub notification.
#
#   ticket_alert=true  -> status became on_sale/sold_out: a dedicated, loud,
#                         deduplicated "may be on sale" issue (this is the one
#                         you actually care about).
#   otherwise          -> ticket text/links changed: a comment on a single
#                         rolling "ticket info changed" issue.
#
# Both paths reuse one open issue instead of spamming new ones. Requires the
# gh CLI (preinstalled on GitHub runners) and GH_TOKEN with issues: write.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT/_report.md"
LABEL="dampfloktage"

STATUS="${STATUS:-unknown}"
ALERT="${ALERT:-false}"
URL="${URL:-}"
RUN_URL="${RUN_URL:-}"

gh label create "$LABEL" --color FFD400 \
    --description "Dampfloktage ticket monitor" 2>/dev/null || true

body="$(cat "$REPORT" 2>/dev/null || echo "Ticket-related content changed.")"
body+=$'\n\n---\n'
[ -n "$RUN_URL" ] && body+="· [workflow run]($RUN_URL) "
[ -n "$URL" ] && body+="· source: ${URL}"

# Find an already-open issue of the given "kind" (matched on its title) so we
# update it instead of opening duplicates.
find_open() {  # $1 = regex to match against issue titles
    gh issue list --state open --label "$LABEL" --limit 50 \
        --json number,title \
        --jq "[.[] | select(.title|test(\"$1\"))][0].number" 2>/dev/null
}

if [ "$ALERT" = true ]; then
    title="🎟️ Dampfloktage: tickets may be on sale"
    existing="$(find_open 'may be on sale')"
    if [ -n "${existing:-}" ] && [ "$existing" != null ]; then
        gh issue comment "$existing" --body "$body"
        gh issue reopen "$existing" 2>/dev/null || true
        echo "commented on on-sale issue #$existing"
    else
        n="$(gh issue create --title "$title" --label "$LABEL" --body "$body" \
             | tail -n1)"
        echo "opened on-sale issue: $n"
    fi
else
    title="🔔 Dampfloktage: ticket info changed"
    existing="$(find_open 'ticket info changed')"
    if [ -n "${existing:-}" ] && [ "$existing" != null ]; then
        gh issue comment "$existing" --body "$body"
        echo "commented on change issue #$existing"
    else
        n="$(gh issue create --title "$title" --label "$LABEL" --body "$body" \
             | tail -n1)"
        echo "opened change issue: $n"
    fi
fi
