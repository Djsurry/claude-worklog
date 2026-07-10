#!/bin/zsh
# Remove the launchd job + skills. Worklog data survives unless --purge.
set -uo pipefail

PLIST="$HOME/Library/LaunchAgents/ai.getbesty.worklog.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/.claude/skills/standup" "$HOME/.claude/skills/recall"
echo "removed launchd job + standup/recall skills"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.claude/worklog"
  echo "purged ~/.claude/worklog (all entries, state, decisions, index)"
else
  echo "kept ~/.claude/worklog (data + scripts); pass --purge to delete it"
fi
