#!/usr/bin/env bash
#
# Fetch the Dampfloktage page, extract the meaningful content, compare it with
# the last committed snapshot in state/, and decide whether anything changed
# and whether tickets have become buyable.
#
# Outputs (to $GITHUB_OUTPUT when set, else stdout):
#   changed         any monitored content differs from the snapshot
#   ticket_changed  ticket text / links / status differ  -> open/update an issue
#   ticket_alert    status transitioned into on_sale|sold_out -> loud alert
#   status          on_sale | sold_out | coming_soon | unknown
#   prev_status     status from the previous run
#   heartbeat_due   true if it's time for a keep-alive commit
#   http            HTTP status code of the fetch
#   url             the monitored URL
#
# Designed to also be runnable locally:  URL=... ./scripts/check.sh
set -euo pipefail

URL="${URL:-https://meiningen.de/events-veranstaltung/dampfloktage}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/state"
REPORT="$ROOT/_report.md"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
UA="Mozilla/5.0 (compatible; dampfloktage-monitor/1.0; +https://github.com/topics/uptime-monitor)"
MARKER="dampflok"          # must appear in a real page; guards against WAF/error pages
HEARTBEAT_MAX_AGE=72000    # 20h: force a keep-alive commit at least ~daily

mkdir -p "$STATE"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

emit() { printf '%s=%s\n' "$1" "$2" >>"$OUT"; }

fail_fetch() {  # $1 = human reason
    local ts; ts="$(date -u +%FT%TZ)"
    printf 'last_check=%s\nepoch=%s\nhttp=%s\nstatus=fetch_failed\nresult=%s\n' \
        "$ts" "$(date -u +%s)" "${http_code:-000}" "$1" >"$STATE/last_check.txt"
    {
        echo "## ⚠️ Dampfloktage monitor: fetch failed"
        echo
        echo "- reason: \`$1\`"
        echo "- http: \`${http_code:-000}\`"
        echo "- url: $URL"
        echo "- time (UTC): $ts"
        echo
        echo "The previous snapshot was left untouched. Will retry next run."
    } >"$REPORT"
    echo "::error::Dampfloktage fetch failed: $1 (http=${http_code:-000})"
    emit changed false
    emit ticket_changed false
    emit ticket_alert false
    emit status fetch_failed
    emit heartbeat_due false
    emit http "${http_code:-000}"
    emit url "$URL"
    exit 1
}

# ---------------------------------------------------------------- fetch -----
# -f          -> non-zero exit on HTTP >=400 (so we can retry / detect it)
# --retry ... -> ride out transient network + 5xx errors within a single run
http_code="$(
    curl -fsSL --compressed \
        --retry 5 --retry-all-errors --retry-delay 6 \
        --connect-timeout 20 --max-time 90 \
        -A "$UA" \
        -o "$tmp/raw.html" \
        -w '%{http_code}' \
        "$URL" 2>"$tmp/curlerr"
)" || fail_fetch "curl error ($(tr -d '\n' <"$tmp/curlerr" | tail -c 200))"

bytes="$(wc -c <"$tmp/raw.html" 2>/dev/null || echo 0)"
[ "$bytes" -ge 1000 ] || fail_fetch "response too small (${bytes} bytes)"
grep -qi "$MARKER" "$tmp/raw.html" || fail_fetch "marker '$MARKER' missing (blocked / wrong page?)"

# -------------------------------------------------------------- extract -----
python3 "$ROOT/scripts/extract.py" "$tmp/new" "$URL" <"$tmp/raw.html"
new_status="$(cat "$tmp/new/status.txt")"
prev_status="$(cat "$STATE/status.txt" 2>/dev/null || echo none)"

# -------------------------------------------------------------- compare -----
differs() { ! cmp -s "$STATE/$1" "$tmp/new/$1" 2>/dev/null; }

if [ ! -f "$STATE/content.txt" ]; then
    # first ever run: establish a baseline, don't cry "changed"
    baseline=true
    changed=true              # so the baseline gets committed
    ticket_changed=false
    c_content=false; c_links=false; c_ctx=false; c_status=false
else
    baseline=false
    c_content=$(differs content.txt && echo true || echo false)
    c_links=$(differs links.txt && echo true || echo false)
    c_ctx=$(differs ticket_context.txt && echo true || echo false)
    c_status=$(differs status.txt && echo true || echo false)
    c_signals=$(differs signals.txt && echo true || echo false)
    changed=false
    for v in "$c_content" "$c_links" "$c_ctx" "$c_status" "$c_signals"; do
        [ "$v" = true ] && changed=true
    done
    ticket_changed=false
    for v in "$c_links" "$c_ctx" "$c_status"; do
        [ "$v" = true ] && ticket_changed=true
    done
fi

# The headline alert: tickets just became (un)buyable.
#
# Robustness note: we do NOT rely on positively recognising the *new* wording
# (the page might announce sales with a phrase we never anticipated -
# "geöffnet", "erhältlich", "Verkauf gestartet", ...). Two independent triggers:
#   1. we positively classified on_sale / sold_out, OR
#   2. the wording we *were* tracking ("coming soon") changed or vanished.
# (2) needs no knowledge of the new text, so reworded/removed notices still fire.
ticket_alert=false
alert_reason=""
case "$new_status" in
    on_sale)
        [ "$new_status" != "$prev_status" ] && {
            ticket_alert=true; alert_reason="tickets appear to be ON SALE"; } ;;
    sold_out)
        [ "$new_status" != "$prev_status" ] && {
            ticket_alert=true; alert_reason="tickets show as SOLD OUT (sales have started)"; } ;;
esac
if [ "$ticket_alert" = false ] && [ "$prev_status" = coming_soon ] \
        && [ "$new_status" != coming_soon ]; then
    ticket_alert=true
    alert_reason="the \"tickets coming soon\" notice changed or disappeared — tickets may now be buyable"
fi

# --------------------------------------------------------------- report -----
# Built while the OLD snapshot is still on disk, so diffs are meaningful.
ts="$(date -u +%FT%TZ)"
{
    if [ "$ticket_alert" = true ]; then
        echo "## 🎟️ Dampfloktage: ${alert_reason}"
        echo
        echo "> Go check the page now: ${URL}"
    elif [ "$ticket_changed" = true ]; then
        echo "## 🔔 Dampfloktage: ticket info changed"
    else
        echo "## Dampfloktage ticket monitor"
    fi
    echo
    echo "| field | value |"
    echo "|---|---|"
    echo "| ticket status | **${new_status}** |"
    echo "| previous status | ${prev_status} |"
    echo "| ticket alert | ${ticket_alert} |"
    echo "| page body changed | ${c_content:-n/a} |"
    echo "| http | ${http_code} |"
    echo "| checked (UTC) | ${ts} |"
    echo "| url | ${URL} |"
    echo
    if [ -s "$tmp/new/signals.txt" ]; then
        echo "### signals"; echo '```'; cat "$tmp/new/signals.txt"; echo '```'; echo
    fi
    for f in status.txt links.txt ticket_context.txt; do
        if [ "$baseline" = false ] && differs "$f"; then
            echo "### diff: $f"; echo '```diff'
            diff -u "$STATE/$f" "$tmp/new/$f" 2>/dev/null | tail -n +3 || true
            echo '```'; echo
        fi
    done
    if [ "$baseline" = true ]; then
        echo "_Baseline snapshot established; no alerts on the first run._"
    fi
} >"$REPORT"

# ----------------------------------------------------- persist new state ----
cp "$tmp/new/"*.txt "$STATE/"

# heartbeat / keep-alive bookkeeping. last_check.txt is the previous run's
# (committed) value -- extract.py never writes it -- so this measures the age
# of the last keep-alive commit. Missing file (first run) -> heartbeat due.
now="$(date -u +%s)"
prev_hb=""
if [ -f "$STATE/last_check.txt" ]; then
    prev_hb="$(sed -n 's/^epoch=//p' "$STATE/last_check.txt" | head -1 || true)"
fi
heartbeat_due=true
if [ -n "$prev_hb" ] && [ $(( now - prev_hb )) -lt "$HEARTBEAT_MAX_AGE" ]; then
    heartbeat_due=false
fi
printf 'last_check=%s\nepoch=%s\nhttp=%s\nstatus=%s\nresult=OK\n' \
    "$ts" "$now" "$http_code" "$new_status" >"$STATE/last_check.txt"

# ---------------------------------------------------------------- outputs ----
emit changed "$changed"
emit ticket_changed "$ticket_changed"
emit ticket_alert "$ticket_alert"
emit status "$new_status"
emit prev_status "$prev_status"
emit heartbeat_due "$heartbeat_due"
emit http "$http_code"
emit url "$URL"

echo "check done: status=$new_status (was $prev_status) changed=$changed ticket_changed=$ticket_changed ticket_alert=$ticket_alert"
