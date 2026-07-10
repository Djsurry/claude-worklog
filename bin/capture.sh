#!/bin/zsh
# Nightly worklog capture. Run by launchd (default ~4:00am) for the day that just ended.
# Stage 1 (this script): deterministic gather -> context.json.
# Stage 2: `claude -p` reads context.json + INSTRUCTIONS.md, writes the day's md + state.json.
set -uo pipefail

WORKLOG="$HOME/.claude/worklog"
BIN="$WORKLOG/bin"
LOGS="$WORKLOG/logs"
mkdir -p "$LOGS"

# Per-user environment written by install.sh: PATH additions (node/claude/gh/linear live outside
# launchd's minimal PATH), AWS_PROFILE, BESTY_REPO_ROOT, LINEAR_USER_ID.
[ -f "$WORKLOG/env.sh" ] && source "$WORKLOG/env.sh"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Modes:
#   capture.sh                -> nightly, target = yesterday
#   capture.sh 2026-07-06     -> re-run one day (full: state.json + priorities)
#   capture.sh --backfill DATE -> historical day: writes DATE.md + decisions.jsonl only,
#                                 never touches live state.json, tickets limited to createdAt==DATE
BACKFILL=0
if [ "${1:-}" = "--backfill" ]; then
  BACKFILL=1
  shift
fi
TARGET="${1:-$(date -v-1d +%Y-%m-%d)}"
WEEKDAY="$(date -j -f %Y-%m-%d "$TARGET" +%A 2>/dev/null || echo '')"
# GitHub search date qualifiers are UTC. The local day spans two UTC dates,
# so query TARGET..TARGET+1 and filter back to the local calendar date in node.
NEXT="$(date -j -v+1d -f %Y-%m-%d "$TARGET" +%Y-%m-%d 2>/dev/null || echo "$TARGET")"
RUNLOG="$LOGS/${TARGET}$([ $BACKFILL -eq 1 ] && echo .backfill).log"
CTX="$WORKLOG/context$([ $BACKFILL -eq 1 ] && echo -bf).json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$RUNLOG"; }

log "=== worklog capture for $TARGET ($WEEKDAY) ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Sessions (local-only signal) ---
log "extracting sessions…"
node "$BIN/extract-sessions.mjs" "$TARGET" > "$TMP/sessions.json" 2>>"$RUNLOG" || echo '[]' > "$TMP/sessions.json"
log "sessions: $(grep -c '"repo"' "$TMP/sessions.json" 2>/dev/null || echo 0) session(s)"

# --- Git across all repos (GitHub API, org-wide) ---
# --author-date is UTC on GitHub's side: a bare =$TARGET drops the local evening window
# and pulls in the previous evening instead. Query both UTC days, filter locally.
log "fetching commits…"
gh search commits --author=@me --author-date="${TARGET}..${NEXT}" --limit 200 \
  --json sha,repository,commit 2>>"$RUNLOG" \
  | TARGET="$TARGET" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let a=[];try{a=JSON.parse(s)}catch{}
      const localDate=(d)=>new Date(d).toLocaleDateString("en-CA"); // host tz, YYYY-MM-DD
      const out=a.map(c=>({repo:c.repository&&c.repository.fullName,sha:(c.sha||"").slice(0,9),date:c.commit&&c.commit.author&&c.commit.author.date,message:(c.commit&&c.commit.message||"").split("\n")[0]}))
        .filter(c=>c.date&&localDate(c.date)===process.env.TARGET);
      process.stdout.write(JSON.stringify(out,null,2));
    });' > "$TMP/git.json" 2>>"$RUNLOG" || echo '[]' > "$TMP/git.json"
log "commits: $(grep -c '"sha"' "$TMP/git.json" 2>/dev/null || echo 0)"

# --- PRs: merged on the target local day + currently open (org-wide) ---
# Merged PRs are the ground truth for "shipped"; sessions only know "PR open at the
# time of the prompt". closedAt == merge time for merged PRs (gh search has no mergedAt).
log "fetching merged PRs…"
gh search prs --author=@me --merged --merged-at="${TARGET}..${NEXT}" --limit 100 \
  --json number,title,repository,closedAt 2>>"$RUNLOG" \
  | TARGET="$TARGET" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let a=[];try{a=JSON.parse(s)}catch{}
      const localDate=(d)=>new Date(d).toLocaleDateString("en-CA");
      const out=a.map(p=>({repo:p.repository&&(p.repository.nameWithOwner||p.repository.fullName),number:p.number,title:p.title,merged_at:p.closedAt}))
        .filter(p=>p.merged_at&&localDate(p.merged_at)===process.env.TARGET);
      process.stdout.write(JSON.stringify(out,null,2));
    });' > "$TMP/prs_merged.json" 2>>"$RUNLOG" || echo '[]' > "$TMP/prs_merged.json"
log "merged PRs: $(grep -c '"number"' "$TMP/prs_merged.json" 2>/dev/null || echo 0)"

log "fetching open PRs…"
gh search prs --author=@me --state=open --limit 50 \
  --json number,title,repository,isDraft,updatedAt 2>>"$RUNLOG" \
  | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let a=[];try{a=JSON.parse(s)}catch{}
      // Cap staleness: years-old open PRs are noise, not "awaiting review".
      const cutoff=Date.now()-14*24*3600*1000;
      const out=a.map(p=>({repo:p.repository&&(p.repository.nameWithOwner||p.repository.fullName),number:p.number,title:p.title,draft:!!p.isDraft,updated_at:p.updatedAt}))
        .filter(p=>p.updated_at&&new Date(p.updated_at).getTime()>=cutoff);
      process.stdout.write(JSON.stringify(out,null,2));
    });' > "$TMP/prs_open.json" 2>>"$RUNLOG" || echo '[]' > "$TMP/prs_open.json"
log "open PRs: $(grep -c '"number"' "$TMP/prs_open.json" 2>/dev/null || echo 0)"

# --- Linear: issues assigned to YOU (optional) ---
# The shared LINEAR_API_KEY is under one identity for the whole team, so `linear issues my`
# returns the key owner's tickets, not yours. Query by your resolved user id instead
# (install.sh resolves it from your email and writes LINEAR_USER_ID into env.sh).
if command -v linear >/dev/null 2>&1 && [ -n "${LINEAR_USER_ID:-}" ]; then
  log "fetching linear issues…"
  linear issues list --assignee "$LINEAR_USER_ID" --limit 100 2>>"$RUNLOG" \
    | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        // strip any non-json warning lines, keep from first "{"
        const i=s.indexOf("{");let o={};try{o=JSON.parse(s.slice(i))}catch{}
        const arr=(o.issues||[]).map(x=>({id:x.identifier,title:x.title,state:x.state&&x.state.name,priority:x.priorityLabel,project:x.project&&x.project.name,branchName:x.branchName,dueDate:x.dueDate,createdAt:x.createdAt,updatedAt:x.updatedAt,url:x.url}));
        process.stdout.write(JSON.stringify(arr,null,2));
      });' > "$TMP/linear.json" 2>>"$RUNLOG" || echo '[]' > "$TMP/linear.json"
  log "linear issues: $(grep -c '"id"' "$TMP/linear.json" 2>/dev/null || echo 0)"
else
  log "linear: skipped (CLI missing or LINEAR_USER_ID unset)"
  echo '[]' > "$TMP/linear.json"
fi

# --- Update the searchable session index (deterministic, cheap). Skip on backfill (already indexed). ---
if [ $BACKFILL -eq 0 ]; then
  log "updating session index…"
  node "$BIN/index-sessions.mjs" --since "$TARGET" 2>>"$RUNLOG" || log "WARN: index update failed"
fi

# --- Previous state (for carryover reconciliation) ---
[ -f "$WORKLOG/state.json" ] && cp "$WORKLOG/state.json" "$TMP/prev_state.json" || echo '{}' > "$TMP/prev_state.json"

# --- Assemble context.json ---
TARGET="$TARGET" WEEKDAY="$WEEKDAY" BACKFILL="$BACKFILL" node -e '
  const fs=require("fs");const t=process.env.TMP||"'"$TMP"'";
  const rd=(f)=>{try{return JSON.parse(fs.readFileSync(f,"utf8"))}catch{return null}};
  const ctx={
    target_date:process.env.TARGET,
    weekday:process.env.WEEKDAY,
    backfill:process.env.BACKFILL==="1",
    sessions:rd(t+"/sessions.json")||[],
    git:rd(t+"/git.json")||[],
    prs_merged:rd(t+"/prs_merged.json")||[],
    prs_open:rd(t+"/prs_open.json")||[],
    linear:rd(t+"/linear.json")||[],
    prev_state:rd(t+"/prev_state.json")||{}
  };
  fs.writeFileSync(t+"/context.json",JSON.stringify(ctx,null,2));
' TMP="$TMP" 2>>"$RUNLOG"
cp "$TMP/context.json" "$CTX"
log "context assembled ($(wc -c < "$CTX" | tr -d ' ') bytes, backfill=$BACKFILL)"

# --- Stage 2: synthesize via claude (Read/Write/Glob only, no prompts) ---
log "synthesizing with claude…"
cd "$WORKLOG"
CTX_NAME="$(basename "$CTX")"
if [ $BACKFILL -eq 1 ]; then
  PROMPT="Read INSTRUCTIONS.md and $CTX_NAME in this directory ($WORKLOG). context.backfill is true: follow the BACKFILL MODE rules in INSTRUCTIONS.md. Write ${TARGET}.md and append to decisions.jsonl ONLY. Do NOT create or modify state.json. Use only Read, Write, and Glob tools."
else
  PROMPT="Read INSTRUCTIONS.md and $CTX_NAME in this directory ($WORKLOG). Then produce the worklog for date $TARGET exactly as INSTRUCTIONS.md specifies: overwrite ${TARGET}.md, update state.json, and append to decisions.jsonl. Use only Read, Write, and Glob tools."
fi

claude -p "$PROMPT" \
  --allowedTools Read Write Glob \
  --model sonnet \
  --add-dir "$WORKLOG" >> "$RUNLOG" 2>&1

RC=$?
if [ $RC -eq 0 ] && [ -f "$WORKLOG/$TARGET.md" ]; then
  log "DONE -> $WORKLOG/$TARGET.md"
else
  log "WARN: synthesis rc=$RC, ${TARGET}.md $( [ -f "$WORKLOG/$TARGET.md" ] && echo exists || echo missing )"
fi
