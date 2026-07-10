---
name: recall
description: Use when the user refers to past work/conversation and wants it found - "do you remember when we...", "we talked about X", "what did we decide/say about X", "have we discussed X before", "find the session where...", "when did we work on X", "didn't we already do X", "the other day we did/built X", "a while back we...", "recently we set up X", "do you see that / do you have that", "what was that thing about X". Any time the user points at prior work by memory rather than giving you the artifact, USE THIS instead of ad-hoc grepping. Searches the local index of all sessions (~/.claude/worklog/index/sessions.jsonl) + the decisions log, reads the top matches, and answers with dated citations and an offer to resume that session.
---

# recall — second-brain retrieval across all Claude Code sessions

The user runs most of their work through Claude Code and loses time hunting old sessions. This skill answers
"do you remember when we…" / "what did we decide about X" from the local session index built by the worklog job.

## Stores
- `~/.claude/worklog/index/sessions.jsonl` — one line per session: `session_id`, `date`, `repo`, `branch`,
  `title`, `tickets[]`, `files[]`, `text` (title + user prompts + assistant prose, generously clipped),
  `gist` (cached summary or null).
- `~/.claude/worklog/decisions.jsonl` — `{date, repo, decision, why, tickets[], session}`.

## Procedure

1. **Extract query terms** from what the user asked (topic words, ticket ids like `BES-\d+`, file names, repos).

2. **Search the index (primary).** Grep `sessions.jsonl` for the terms across `text`/`title`/`tickets`/`files`.
   Rank candidates by: term-overlap count, then ticket/file exact hits, then recency (`date` desc). Example:
   `grep -iE 'pgvector|embedding|pinecone' ~/.claude/worklog/index/sessions.jsonl`.
   For "what did we decide" style questions, grep `decisions.jsonl` first — it's the direct answer.

3. **Full-text / recency fallback.** Raw-grep the transcripts when EITHER the index is thin (rare/exact
   identifiers — a variable name, an error string) OR the query implies very recent work ("the other day",
   "earlier", "just now") — the index only rebuilds nightly, so **today's sessions are not in it yet**.
   `grep -rl -iE '<term>' ~/.claude/projects/*/*.jsonl` (top level only; skip `subagents/`). Map matching
   files back to index entries by `session_id` (the filename without `.jsonl`); files with no index entry
   are simply un-indexed recent sessions — read them directly.

4. **Read the top 2-4 sessions.** Open those transcript files
   (`~/.claude/projects/<encoded-cwd>/<session_id>.jsonl`) and read the relevant turns. Synthesize a direct
   answer: what was discussed/decided, the key points, and any outcome (commit/ticket/PR mentioned).

5. **Answer with citations.** For each relevant session: `**<date> · <repo>** — <one-line what it was>`
   then the substance. Be concise. Then offer next actions:
   - Resume it: `claude --resume <session_id>` (tell the user the exact command).
   - Open a related ticket (`linear issues get BES-XXXX`) or pull up the PR.

6. **Lazy enrichment (optional).** If a surfaced session had `gist: null`, write a one-line gist back into
   its index entry so future recalls are faster (rewrite that line in `sessions.jsonl`).

## Notes
- Only top-level session files are real conversations; `subagents/agent-*.jsonl` are internal fan-out, ignore them.
- If nothing matches, say so plainly and suggest broader terms rather than guessing.
- Keep answers tight. Lead with the answer, then the citation, then the offer.
