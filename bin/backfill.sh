#!/bin/zsh
# One-time historical backfill of daily worklogs from the session index.
# Serial (cheap, sonnet), resumable (skips days whose .md already exists).
# Processes every indexed active day strictly before CUTOFF (default: today).
# Runs for hours; launch it detached (see README).
set -uo pipefail

WORKLOG="$HOME/.claude/worklog"
BIN="$WORKLOG/bin"
LOGS="$WORKLOG/logs"
mkdir -p "$LOGS"
[ -f "$WORKLOG/env.sh" ] && source "$WORKLOG/env.sh"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

DRIVERLOG="$LOGS/backfill-driver.log"
CUTOFF="${1:-$(date +%Y-%m-%d)}"

dlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DRIVERLOG"; }

if [ ! -f "$WORKLOG/index/sessions.jsonl" ]; then
  dlog "no session index yet; building it first (node bin/index-sessions.mjs --all)…"
  node "$BIN/index-sessions.mjs" --all || { dlog "index build failed"; exit 1; }
fi

# Active days from the index, strictly before CUTOFF, ascending (oldest first for clean dedup).
days=$(CUTOFF="$CUTOFF" node -e '
  const fs=require("fs");const s=new Set();
  fs.readFileSync(process.env.HOME+"/.claude/worklog/index/sessions.jsonl","utf8").trim().split("\n").forEach(l=>{try{const o=JSON.parse(l);if(o.date)s.add(o.date)}catch{}});
  [...s].filter(d=>d < process.env.CUTOFF).sort().forEach(d=>console.log(d));
')

total=$(echo "$days" | grep -c .)
dlog "=== backfill start: $total active day(s) before $CUTOFF ==="

i=0
for d in ${(f)days}; do
  i=$((i+1))
  if [ -f "$WORKLOG/$d.md" ]; then
    dlog "[$i/$total] skip $d (already exists)"
    continue
  fi
  dlog "[$i/$total] backfilling $d …"
  "$BIN/capture.sh" --backfill "$d" >>"$DRIVERLOG" 2>&1
  if [ -f "$WORKLOG/$d.md" ]; then
    dlog "[$i/$total] $d done"
  else
    dlog "[$i/$total] $d FAILED (no md produced)"
  fi
done

dlog "=== backfill complete ==="
