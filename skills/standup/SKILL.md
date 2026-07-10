---
name: standup
description: Use when the user asks "what's on the go today", "standup", "what's on the go", "what did we do yesterday", "what's my day look like", "what's in the someday backlog", "what ideas did I park", or otherwise wants their personal daily plan / worklog summary / parked-ideas backlog. Reads the local worklog (~/.claude/worklog) that the nightly job generates and reconciles it with live Linear and merged/open GitHub PRs.
---

# Standup / "what's on the go today"

Personal daily planning readout. The nightly worklog job (launchd, default ~4am) writes
`~/.claude/worklog/<date>.md` + `state.json`. This skill reads that and freshens it against live Linear
AND live GitHub PR state. Both freshen steps are mandatory; state.json alone is always hours stale.

## Steps

1. **Read the rolling state**: `~/.claude/worklog/state.json`. This has `priorities_next`, `carryover`,
   `deferred`, `open_tickets`. It is the backbone of the answer.
2. **Read recent entries**: the most recent 1-2 `~/.claude/worklog/*.md` (yesterday, and today if it exists).
   Use `ls ~/.claude/worklog/*.md | tail -3`. If none exist, say the log is not populated yet (nightly job
   runs at the configured hour; offer to run `~/.claude/worklog/bin/capture.sh` now for the prior day).
3. **Freshen from live Linear** (state.json may be hours stale): read `linear_user_id` from
   `~/.claude/worklog/config.json`, then run
   `linear issues list --assignee <linear_user_id> --limit 100 2>/dev/null` and diff current states against
   `open_tickets` — flag anything that moved (e.g. now awaiting review, now blocked, newly assigned, newly
   closed). Do NOT use `linear issues my`: the CLI key is shared, so "my" is someone else's identity.
   If `linear_user_id` is missing or the `linear` CLI is absent, skip this step and say so in one line.
4. **Freshen from merged PRs — MANDATORY, Linear cannot catch these.** Most `priorities_next`/`carryover`
   items have `ticket: null` and live as PRs; skipping this step is how already-merged work gets read out as
   "top priority today" (happened 2026-07-09: priorities 1, 2, 4 were all merged hours earlier). Run
   (needs sandbox disabled for gh):

   ```bash
   gh pr list --author "@me" --state merged --search "merged:>=<state.updated_for>" \
     --json number,title,headRefName,mergedAt
   gh pr list --author "@me" --state open --json number,title,headRefName,isDraft
   ```

   Match merged PRs against `priorities_next`/`carryover` items by title/branch keywords. Anything matched:
   move it to a "Done since the snapshot" line at the top, do NOT list it as a priority. Renumber remaining
   priorities. If a carryover item names a repo other than the current one (e.g. `repo: "carbon"`), also
   check that repo (`gh pr list -R <org>/<repo> ...`). Open PRs by the user = "awaiting review", not
   "needs building".
5. **If asked specifically about yesterday** ("what did we do yesterday"): just summarize yesterday's `.md`.

## Output (default "what's on the go today")

Lead with the plan, keep it tight and skimmable. No em dashes.

- **Done since the snapshot** — priorities/carryover whose PRs merged (from step 4), one line each. Lead with
  this when non-empty so stale wins are celebrated, not re-assigned.
- **Top priorities today** — from `state.priorities_next` minus anything merged, each with its one-line why.
- **Carryover / in progress** — from `state.carryover`, with `days_open` and the next step. Age-flag anything
  open 3+ days.
- **Deferred worth a look** — from `state.deferred`.
- **Tickets** — new / awaiting-review / blocked, reconciled with the live Linear pull. Note any drift since
  the nightly snapshot.
- **Blockers** — anything that reads as stuck.

Do NOT dump the full `someday` backlog in the daily readout. Instead close with a one-liner:
"N parked ideas in the someday backlog (ask to see them)." Age-flag any someday item with a high `mentions`
count or one that keeps recurring, since repeated mentions signal it's becoming real.

## Output ("what's in the someday backlog" / "what ideas did I park")

Read `state.someday` and list every item: the idea, its `context`, `first_mentioned`, and `mentions`
(sort by mentions desc, then oldest first). Flag anything mentioned 3+ times as "worth promoting to a ticket."
Offer to create a Linear ticket (`linear issues create ...`) for any the user picks.

Be concise. Offer to open any ticket (`linear issues get BES-XXXX`) or dig into a carryover item on request.
