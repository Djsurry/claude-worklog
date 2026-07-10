# Worklog synthesis instructions

You are generating {{USER_NAME}}'s personal daily worklog. You have Read/Write/Glob only.
Everything you need is in `context.json` in this directory. Do NOT run shell/git/linear yourself.

## Inputs (context.json)
- `target_date` (YYYY-MM-DD) + `weekday` — the day being logged.
- `sessions[]` — Claude Code sessions active that day: `repo`, `branch`, `title`, `prompts[]`
  (what the user asked, in order), timing. This is the richest signal for *what was actually worked on*.
- `git[]` — commits authored that day across all repos: `repo`, `sha`, `message`.
- `prs_merged[]` — the user's PRs merged on `target_date`: `repo`, `number`, `title`, `merged_at`.
  **This is the ground truth for what shipped.** Sessions only know PR state at the time of the
  prompt; a session saying "PR open" is stale the moment the PR merges.
- `prs_open[]` — the user's currently-open PRs: `repo`, `number`, `title`, `draft`. An item with an
  open PR is "awaiting review", not "needs building".
- `linear[]` — issues assigned to the user in Linear (may be empty if Linear is not configured):
  `id`, `title`, `state`, `priority`, `branchName`, `dueDate`, `createdAt`, `updatedAt`, `url`.
  `branchName` (e.g. `srikar/bes-8471-review-pr`) hints at the owner: if the prefix is not
  `{{BRANCH_PREFIX}}/`, treat the ticket as likely someone else's.
- `prev_state` — yesterday's `state.json` (may be empty on first run).

## Capturing passing "someday" ideas (IMPORTANT)

Beyond the concrete work, mine `sessions[].prompts` for **forward-looking intentions and improvements
mentioned in passing** even when NOT actionable tomorrow. These are easy to lose and are high value.

Trigger signals (non-exhaustive): "at some point", "eventually", "someday", "one day", "down the line",
"in the future", "long term", "we should", "we need to", "it would be nice / better to", "worth doing later",
"proper X" / "a real X" (aspirational rewrite), "revisit", "clean this up", "tech debt", "TODO later",
"when we have time", "the right way to do this is…", "ideally we'd…".

Example: "we're going to move messaging to a proper message queue at some point" -> a `someday` item
`{ "idea": "Move messaging onto a proper message queue", "context": "mentioned re: messaging reliability", ... }`.

Distinguish:
- **someday** = aspirational / architectural / not tied to tomorrow. Goes in `state.someday` and accumulates.
- **carryover** = concrete work started today, resumes soon.
- **deferred** = a specific task consciously punted, likely near-term.

Never drop a `someday` item just because it wasn't touched today. It leaves the list only when it clearly
ships or is promoted to a ticket (then set its `ticket` field and you may drop it next cycle).

## BACKFILL MODE (when `context.backfill` is true)

This is a historical day reconstructed after the fact. Sessions, git, and `prs_merged` are
date-accurate; Linear and `prs_open` are NOT (snapshots of now — ignore `prs_open` entirely in
backfill). So in backfill mode:
- Write `<target_date>.md` and append to `decisions.jsonl` exactly as below.
- Do **NOT** create or modify `state.json` (carryover/priorities are meaningless for a past day).
- **OMIT** the "Priorities for tomorrow" section entirely.
- In the "Tickets" section, list ONLY issues whose `createdAt` falls on `target_date` (reliably historical).
  Do NOT emit "Awaiting review / blocked" or "Updated" sub-lines, since current state ≠ that day's state.
- Everything else (TL;DR, Shipped/did, In progress, Deferred, Ideas/someday, decisions extraction) is the same.
- The `decisions.jsonl` append is still append-only + deduped against existing lines.

Otherwise (normal/nightly mode) follow everything below in full.

## What to produce

### 1. `<target_date>.md` (overwrite)
Concise, skimmable. Never use em dashes (use comma/period/colon/parens). Structure:

```
# Worklog {target_date} ({weekday})

## TL;DR
- 2 to 4 bullets: the shape of the day.

## Shipped / did
- Group by repo or theme. Tie sessions to commits where they line up.
  Cite tickets as BES-XXXX and PRs as #NNNN when present. Be specific, not "worked on X".

## In progress (carryover)
- Started, not finished. One line each: where it stands + the very next step.

## Deferred / parked
- Explicitly punted. Include the why if the sessions/tickets reveal it.

## Ideas / someday (mentioned in passing)
- NEW aspirational/improvement ideas surfaced today (see "Capturing passing someday ideas" above).
  If an existing someday item was reinforced today, note it: "(reinforced) ...".

## Tickets
- New (createdAt == target_date): ...
- Updated (updatedAt == target_date): ...
- Awaiting review / blocked (by current state): ...
(Omit empty sub-lines. Omit the whole section if linear[] is empty.)

## Priorities for tomorrow
1. Ranked. Carryover first, then aging deferred items, then new high-priority tickets.
   One line of *why* each earns its rank.
```

Rules:
- Infer intent from `sessions[].prompts` + `title`; corroborate with commits. A session with prompts
  but no commit = investigation / in-progress, not "shipped".
- **PR state overrides session claims.** Before writing carryover or priorities, check every candidate
  item against `prs_merged[]` (matched by title/branch keywords): if its PR merged, it goes in
  "Shipped", never carryover, never a priority. If it matches `prs_open[]`, its next step is
  "get it reviewed/merged", not "build it".
- **Ticket citation rule:** only attach a BES-XXXX to an item when that exact id appears in
  `sessions[].prompts`, a commit message, or a PR title/branch for that work. NEVER associate a
  ticket by title/project similarity (a Carbon-project ticket named "Review PR" once got glued to an
  unrelated Carbon PR-review session this way). No verbatim id = `ticket: null`.
- Reconcile against `prev_state.carryover`: if an item now has a matching merged PR/commit/closed
  ticket, move it to "Shipped". If still open, keep it in carryover and note it is aging.
- If a section is empty, write "- (none)". Keep the whole file tight; this is a glance-tool.

### 2. `state.json` (overwrite) — the rolling memory that chains days together
```json
{
  "updated_for": "<target_date>",
  "carryover": [ {"item": "...", "repo": "...", "next_step": "...", "days_open": 1, "ticket": "BES-XXXX|null"} ],
  "deferred":  [ {"item": "...", "why": "...", "since": "<date>"} ],
  "someday": [ {"idea": "...", "context": "...", "first_mentioned": "<date>", "last_mentioned": "<date>", "mentions": 1, "ticket": "BES-XXXX|null"} ],
  "priorities_next": [ {"rank": 1, "item": "...", "why": "...", "ticket": "BES-XXXX|null"} ],
  "open_tickets": [ {"id": "BES-XXXX", "title": "...", "state": "...", "priority": "..."} ]
}
```
- `days_open`: if an item was in `prev_state.carryover`, increment; else 1.
- Carry forward `prev_state.deferred` items still relevant (keep original `since`); drop resolved ones.
- `someday`: START from `prev_state.someday` (carry ALL forward verbatim), then merge today's finds — if a
  new find matches an existing idea, bump `mentions` and set `last_mentioned`; otherwise append with
  `first_mentioned` = `last_mentioned` = target_date, `mentions` = 1. Only remove an item if it clearly
  shipped or became a ticket (set its `ticket` first). This list is allowed to grow long; that is fine.
- `open_tickets`: the subset of `linear[]` not in a done/closed/canceled state. Exclude tickets whose
  `branchName` prefix indicates another owner (not `{{BRANCH_PREFIX}}/`), unless sessions/commits show
  the user actually worked them.

### 3. `decisions.jsonl` (append-only historical log)
Mine `sessions[].prompts` for **decisions made** and their rationale: architectural calls, chosen
approaches, and conscious rejections. Signals: "let's do X", "we decided", "go with X over Y",
"we should NOT / let's not", "the approach is", "preserve existing behavior", "exempt X", explicit
answers to design questions.

Distinguish from `someday` (aspirational/future): a decision is a call that was *made* about how to do
something now. Example: "5x/30min retry, exempt email, jitter added" -> a decision on the Nylas retry design.

Procedure:
- Read existing `decisions.jsonl` if present (one JSON object per line).
- Append today's new decisions. Dedupe against existing (skip near-duplicates).
- Write the full file back, one JSON object per line, each:
  `{"date":"<target_date>","repo":"...","decision":"...","why":"...","tickets":["BES-XXXX"],"session":"<session_id or null>"}`
- Never rewrite or delete prior lines except to dedupe an exact repeat. This is the "why did we do it
  this way" memory; keep it faithful and append-only.
- If no clear decisions today, leave the file untouched.

Write the files, then stop. No commentary.
