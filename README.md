# claude-worklog

Auto-generated personal daily worklog + second-brain retrieval for anyone who runs most of their
work through Claude Code. Local-only: it reads your local Claude session transcripts, which no
cloud job can see.

Built by David + Claude, July 2026.

## What you get

- **Nightly worklog** (`~/.claude/worklog/<date>.md`): every night at ~4am a launchd job gathers
  your Claude Code sessions, GitHub commits/PRs, and Linear tickets for the day, then has
  `claude -p` synthesize a skimmable daily entry: TL;DR, shipped, in-progress, deferred, ideas,
  priorities for tomorrow.
- **Rolling state** (`state.json`): carryover, deferred items, a growing **someday** backlog of
  ideas you mentioned in passing, and ranked next-day priorities. Chains day to day.
- **Decision log** (`decisions.jsonl`): append-only "why did we do it this way" record, mined
  from your sessions.
- **Session index** (`index/sessions.jsonl`): searchable index of every Claude session ever.
- **Two skills** installed into `~/.claude/skills/`:
  - `standup` — ask Claude "what's on the go today" / "what did we do yesterday" / "what ideas
    did I park". Reads the worklog and freshens it against live Linear + GitHub PR state.
  - `recall` — ask "do you remember when we…" / "what did we decide about X". Searches the
    index + decision log and answers with dated citations and a `claude --resume` command.

## Requirements

- macOS (launchd). Machine sleeps at night? launchd runs the job at next wake.
- `claude` CLI (Claude Code), `node` (>=18), `gh` (authenticated).
- Optional: the besty repo checkout with the `linear` CLI shim + AWS `besty-dev` creds, for the
  Linear ticket sections. Everything else works without it.

## Install

```bash
git clone git@github.com:bloomai/claude-worklog.git
cd claude-worklog
./install.sh
```

The installer prompts for your name, email (used to find YOUR Linear tickets: the shared
`linear` CLI key is under Srikar's identity, so `linear issues my` returns his tickets, not
yours), git branch prefix (e.g. `david`), AWS profile, and run hour. It:

1. Copies scripts to `~/.claude/worklog/bin/` and renders `INSTRUCTIONS.md` (the synthesis
   prompt) with your name/prefix. Existing worklog data (`*.md`, `state.json`,
   `decisions.jsonl`, `index/`) is never touched.
2. Writes `~/.claude/worklog/config.json` + `env.sh` (paths, AWS profile, your resolved Linear
   user id).
3. Installs the `standup` and `recall` skills to `~/.claude/skills/`.
4. Loads the launchd job (`ai.getbesty.worklog`, daily at your chosen hour).

Re-running the installer is safe; it re-renders config/scripts and reloads the job.

## Try it

- Run last night's capture right now: `~/.claude/worklog/bin/capture.sh`
- Then ask Claude: **"what's on the go today"** or **"do you remember when we …"**

## Backfill history

`~/.claude/worklog/bin/backfill.sh [CUTOFF]` regenerates a `.md` + decisions for every indexed
day before CUTOFF (default: today). Resumable (skips existing days), never touches `state.json`.
It runs for hours; launch it detached:

```bash
cd ~/.claude/worklog && nohup ./bin/backfill.sh >> logs/backfill-driver.log 2>&1 </dev/null & disown
```

## Operate it

- Re-run a specific day (full, updates state): `~/.claude/worklog/bin/capture.sh 2026-07-06`
- Re-run a historical day (no state changes): `~/.claude/worklog/bin/capture.sh --backfill 2026-07-06`
- Rebuild the whole session index: `node ~/.claude/worklog/bin/index-sessions.mjs --all`
- Stop / start the nightly job:
  `launchctl unload ~/Library/LaunchAgents/ai.getbesty.worklog.plist` (and `load` to resume)
- Change model/scope: edit `~/.claude/worklog/bin/capture.sh`. Output format: `INSTRUCTIONS.md`.
- Logs: `~/.claude/worklog/logs/` (per-day run logs + launchd stdout/err).

## Privacy note

Everything stays on your machine except the Stage-2 synthesis call (`claude -p` over your day's
prompts + commit titles) — same data path as using Claude Code itself. The worklog directory is
not synced or committed anywhere by this tool.

## Uninstall

```bash
./uninstall.sh          # removes launchd job + skills; keeps your worklog data
./uninstall.sh --purge  # also deletes ~/.claude/worklog entirely
```
