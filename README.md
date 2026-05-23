# Dampfloktage ticket watcher

A GitHub Actions workflow that watches the Meiningen **Dampfloktage** event page

> https://meiningen.de/events-veranstaltung/dampfloktage

and opens a GitHub issue (which emails you) when the page changes — in
particular **when tickets become buyable**.

Right now the page only says *"Die Tickets sind bald hier für Sie verfügbar"*
("tickets available here soon"). This watcher tells you the moment that stops
being true.

## How it works

Every run (`scripts/check.sh`):

1. **Fetches** the page with curl — realistic User-Agent, retries on transient
   network/5xx errors, timeouts.
2. **Sanity-checks** the response: a minimum size and a required marker word
   (`dampflok`). A blocked/WAF/error page therefore can *not* be mistaken for a
   real change — the run fails loudly instead of corrupting the snapshot.
3. **Extracts** only the meaningful parts (`scripts/extract.py`, Python stdlib
   only): it drops `<script>/<style>/<nav>/<footer>/...`, strips tracking query
   params from links, and normalizes whitespace, so noise (galleries, menus,
   cookie banners, analytics) does **not** trigger false alarms.
4. **Classifies** ticket availability into `coming_soon | on_sale | sold_out |
   unknown` from several independent signals (see *Robustness* below).
5. **Compares** with the last snapshot committed under `state/` and decides:
   - `changed` — any monitored content differs (→ commit the new snapshot).
   - `ticket_changed` — ticket text/links/status differ (→ issue).
   - `ticket_alert` — tickets likely became buyable (→ **loud** issue).
6. **Notifies** (`scripts/alert.sh`): opens or updates a *single* deduplicated
   issue (labelled `dampfloktage`) instead of spamming a new one each run.
7. **Commits** the snapshot back to the repo, so you get a full git history /
   diff of how the page evolved.

A run summary (status + diffs) is also written to the Actions **job summary**.

## Robustness — why it won't quietly miss the sale

The thing you actually care about is a one-time event that happens once and may
sell out fast, so the design favors *over*-alerting (easy to dismiss) over
missing it:

- **It does not depend on guessing the new wording.** We can't know whether the
  site will announce sales with "geöffnet", "erhältlich", "Verkauf gestartet",
  a price, or just a new shop button. So besides positively detecting on-sale
  signals (links to known ticket vendors — Reservix, Eventim, ticket.io, … —
  prices, "Vorverkauf" + a date, "jetzt erhältlich", …), the watcher also fires
  the loud alert whenever the **known "coming soon" notice it was tracking
  changes or disappears**. That trigger needs zero knowledge of the replacement
  text.
- **Any** change to the ticket text or links opens at least a (quieter) issue,
  so even an unclassifiable change gets a human look.
- **Fetch failures don't lie.** A failed/blocked fetch fails the job (GitHub
  emails you about failed scheduled runs) and leaves the last good snapshot
  intact — it never reports a phantom change or a phantom "on sale".
- **No false positives from noise.** Verified: two consecutive fetches of the
  real page produce zero diff.
- **The monitor proves it's alive.** A heartbeat (`state/last_check.txt`) is
  committed at least ~daily; that doubles as repo activity so the scheduled
  workflow is not auto-disabled (GitHub disables schedules after 60 days of repo
  inactivity).

These behaviors are covered by the scenario tests described under *Testing*.

## Deploy

1. Create a GitHub repo (a **public** repo gets unlimited Actions minutes; a
   private one uses your monthly quota — see *Cadence*).
2. Put these files in it and push to the **default branch** (`main`) —
   scheduled workflows only run from the default branch:

   ```
   .github/workflows/monitor.yml
   scripts/check.sh
   scripts/extract.py
   scripts/alert.sh
   state/.gitkeep
   ```

3. Repo **Settings → Actions → General → Workflow permissions** → enable
   **Read and write permissions** (lets the job commit snapshots and open
   issues). The workflow also requests this via its `permissions:` block.
4. Make sure you'll be notified: GitHub emails you for issues in your own repo
   by default; otherwise **Watch → All Activity** on the repo.
5. (Optional) Trigger it once now: **Actions → Watch Dampfloktage tickets →
   Run workflow**. The first run just records a baseline (no alert).

That's it — no secrets or external services required; it uses the built-in
`GITHUB_TOKEN`.

## Cadence

Default: **hourly** (`cron: "23 * * * *"`). Edit the `schedule` in
`.github/workflows/monitor.yml`:

```yaml
- cron: "23 * * * *"        # hourly (default)
# - cron: "23 */3 * * *"    # every 3 hours
# - cron: "23 6,12,18 * * *"# 3x a day
```

Notes:
- GitHub cron is best-effort and may be delayed by a few minutes under load;
  that's why we run at `:23`, not on the hour.
- Hourly ≈ 720 runs/month. On a private repo that's ~720 of your 2000 free
  minutes — make the repo public, or reduce the frequency.

## Testing locally

The logic runs without GitHub:

```bash
# one real check (writes state/ and _report.md, prints outputs)
URL=https://meiningen.de/events-veranstaltung/dampfloktage ./scripts/check.sh

# just the extractor, on any saved HTML
curl -s https://meiningen.de/events-veranstaltung/dampfloktage \
  | python3 scripts/extract.py /tmp/out https://meiningen.de/events-veranstaltung/dampfloktage
cat /tmp/out/status.txt /tmp/out/signals.txt
```

To exercise the decision logic (coming→on_sale, coming→reworded/unknown,
no-change, blocked page), serve crafted HTML files (each containing the word
`dampflok`, ≥1 KB) with `python3 -m http.server` and point `URL` at them.

## Tuning the detection

All heuristics live at the top of `scripts/extract.py`:

- `VENDOR` — known ticket-shop domains (add the one Meiningen ends up using).
- `COMING` — "not yet on sale" phrases.
- `ON_SALE` — "available now" phrases.
- `TICKET_KW` / `BUY_TEXT` — words that mark ticket text and buy buttons.

`scripts/check.sh` top: `URL`, `MARKER`, `HEARTBEAT_MAX_AGE`.

## Files

| path | purpose |
|---|---|
| `.github/workflows/monitor.yml` | schedule, permissions, commit + notify steps |
| `scripts/check.sh` | fetch, sanity-check, diff, decide, write report |
| `scripts/extract.py` | HTML → normalized text + ticket links + status |
| `scripts/alert.sh` | open/update the deduplicated GitHub issue |
| `state/` | committed snapshot + heartbeat (the watcher's memory) |

## Limitations

- Detection is heuristic. If the shop link is injected by JavaScript *and* the
  "coming soon" text never changes server-side, the link itself may not appear
  in the static HTML — but in practice that notice is server-rendered, so its
  change still fires the alert. When in doubt, the alert says *"go check the
  page"* and links to it.
- Treat an alert as "go look now", not as a guarantee tickets are on sale.
