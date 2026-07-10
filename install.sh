#!/bin/zsh
# claude-worklog installer. Idempotent: re-run any time to update scripts/config;
# existing worklog data (*.md, state.json, decisions.jsonl, index/) is never touched.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKLOG="$HOME/.claude/worklog"
SKILLS="$HOME/.claude/skills"
PLIST="$HOME/Library/LaunchAgents/ai.getbesty.worklog.plist"

say()  { echo "\033[1m$*\033[0m"; }
warn() { echo "\033[33mWARN:\033[0m $*"; }
die()  { echo "\033[31mERROR:\033[0m $*"; exit 1; }

# --- dependency checks ---
command -v claude >/dev/null || die "claude CLI not found. Install Claude Code first."
command -v gh >/dev/null || die "gh CLI not found (brew install gh; gh auth login)."
command -v node >/dev/null || die "node not found (>=18 required)."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

HAVE_LINEAR=0
command -v linear >/dev/null 2>&1 && HAVE_LINEAR=1

# --- prompts (defaults from git/gh where possible) ---
prev() { # read a key from an existing config.json, else empty
  [ -f "$WORKLOG/config.json" ] || { echo ""; return; }
  node -e "try{const c=require('$WORKLOG/config.json');process.stdout.write(String(c['$1']??''))}catch{}"
}

DEF_NAME="$(prev name)"; [ -n "$DEF_NAME" ] || DEF_NAME="$(git config --global user.name 2>/dev/null || echo '')"
DEF_EMAIL="$(prev email)"; [ -n "$DEF_EMAIL" ] || DEF_EMAIL="$(git config --global user.email 2>/dev/null || echo '')"
DEF_PREFIX="$(prev branch_prefix)"; [ -n "$DEF_PREFIX" ] || DEF_PREFIX="$(echo "${DEF_EMAIL%%@*}" | tr '[:upper:]' '[:lower:]')"
DEF_AWS="$(prev aws_profile)"; [ -n "$DEF_AWS" ] || DEF_AWS="besty-dev"
DEF_HOUR="$(prev run_hour)"; [ -n "$DEF_HOUR" ] || DEF_HOUR="4"
DEF_BESTY="$(prev besty_repo_root)"; [ -n "$DEF_BESTY" ] || DEF_BESTY="$HOME/besty"

ask() { # ask "Prompt" default -> REPLY
  local prompt="$1" def="$2"
  printf "%s [%s]: " "$prompt" "$def"
  read -r REPLY
  [ -n "$REPLY" ] || REPLY="$def"
}

say "== claude-worklog install =="
ask "Your name (appears in the synthesis prompt)" "$DEF_NAME"; NAME="$REPLY"
ask "Your work email (used to find YOUR Linear tickets)" "$DEF_EMAIL"; EMAIL="$REPLY"
ask "Your git branch prefix (e.g. david in david/bes-1234-fix)" "$DEF_PREFIX"; PREFIX="$REPLY"
ask "AWS profile (for the linear CLI's shared key; blank to skip Linear)" "$DEF_AWS"; AWS="$REPLY"
ask "Nightly run hour (0-23, local time)" "$DEF_HOUR"; HOUR="$REPLY"
ask "Besty repo root (for the linear CLI; blank to skip Linear)" "$DEF_BESTY"; BESTY="$REPLY"
[ -n "$NAME" ] || die "name is required"
echo "$HOUR" | grep -qE '^([0-9]|1[0-9]|2[0-3])$' || die "run hour must be 0-23"

# --- resolve Linear user id from email (optional) ---
# The team's LINEAR_API_KEY is a single shared key, so `linear issues my` returns the key
# owner's tickets. We resolve YOUR user id once here and query by assignee instead.
LINEAR_USER_ID="$(prev linear_user_id)"
if [ $HAVE_LINEAR -eq 1 ] && [ -n "$EMAIL" ] && [ -n "$AWS" ] && [ -d "$BESTY/codingAgentTools/linear" ]; then
  say "Resolving your Linear user id ($EMAIL)…"
  RESOLVED="$(cd "$BESTY/codingAgentTools/linear" && AWS_PROFILE="$AWS" node -e '
    import("@besty/secrets").then(async ({getSecret}) => {
      const key = await getSecret("LINEAR_API_KEY");
      const r = await fetch("https://api.linear.app/graphql", {method:"POST",
        headers:{"Content-Type":"application/json", Authorization:key},
        body: JSON.stringify({query:`query($e:String!){ users(filter:{email:{eq:$e}}){ nodes { id name email } } }`,
          variables:{e: process.argv[1]}})});
      const j = await r.json();
      const u = j.data && j.data.users && j.data.users.nodes && j.data.users.nodes[0];
      if (u) process.stdout.write(u.id);
    }).catch(()=>{});' "$EMAIL" 2>/dev/null || echo '')"
  if [ -n "$RESOLVED" ]; then
    LINEAR_USER_ID="$RESOLVED"
    say "  -> $LINEAR_USER_ID"
  else
    warn "could not resolve Linear user id (check AWS creds / email). Linear sections will be skipped."
    warn "re-run ./install.sh later to retry; everything else works without it."
  fi
else
  [ $HAVE_LINEAR -eq 1 ] || warn "linear CLI not on PATH; Linear sections will be skipped (optional)."
fi

# --- lay down files ---
mkdir -p "$WORKLOG/bin" "$WORKLOG/logs" "$WORKLOG/index" "$SKILLS"
cp "$REPO_DIR/bin/"*.sh "$REPO_DIR/bin/"*.mjs "$WORKLOG/bin/"
chmod +x "$WORKLOG/bin/"*.sh

sed -e "s|{{USER_NAME}}|$NAME|g" -e "s|{{BRANCH_PREFIX}}|$PREFIX|g" \
  "$REPO_DIR/INSTRUCTIONS.template.md" > "$WORKLOG/INSTRUCTIONS.md"

node -e '
  const fs=require("fs");
  const [name,email,prefix,aws,hour,besty,lid]=process.argv.slice(1);
  fs.writeFileSync(process.env.HOME+"/.claude/worklog/config.json", JSON.stringify({
    name, email, branch_prefix:prefix, aws_profile:aws||null, run_hour:Number(hour),
    besty_repo_root:besty||null, linear_user_id:lid||null,
    installed_from:"'"$REPO_DIR"'", installed_at:new Date().toISOString()
  },null,2)+"\n");
' "$NAME" "$EMAIL" "$PREFIX" "$AWS" "$HOUR" "$BESTY" "$LINEAR_USER_ID"

# env.sh: sourced by capture/backfill under launchd (minimal PATH there).
NODE_DIR="$(dirname "$(command -v node)")"
CLAUDE_DIR="$(dirname "$(command -v claude)")"
GH_DIR="$(dirname "$(command -v gh)")"
LINEAR_DIR=""
[ $HAVE_LINEAR -eq 1 ] && LINEAR_DIR="$(dirname "$(command -v linear)")"
{
  echo "# generated by claude-worklog install.sh $(date '+%Y-%m-%d %H:%M'); re-run install.sh to regenerate"
  echo "export PATH=\"$NODE_DIR:$CLAUDE_DIR:$GH_DIR${LINEAR_DIR:+:$LINEAR_DIR}:\$PATH\""
  [ -n "$AWS" ] && echo "export AWS_PROFILE=\"\${AWS_PROFILE:-$AWS}\""
  [ -n "$BESTY" ] && echo "export BESTY_REPO_ROOT=\"\${BESTY_REPO_ROOT:-$BESTY}\""
  [ -n "$LINEAR_USER_ID" ] && echo "export LINEAR_USER_ID=\"$LINEAR_USER_ID\""
} > "$WORKLOG/env.sh"

# skills
mkdir -p "$SKILLS/standup" "$SKILLS/recall"
cp "$REPO_DIR/skills/standup/SKILL.md" "$SKILLS/standup/SKILL.md"
cp "$REPO_DIR/skills/recall/SKILL.md" "$SKILLS/recall/SKILL.md"

# launchd job
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|{{HOME}}|$HOME|g" -e "s|{{RUN_HOUR}}|$HOUR|g" \
  "$REPO_DIR/launchd.template.plist" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

say ""
say "Installed."
echo "  worklog dir : $WORKLOG"
echo "  nightly job : ai.getbesty.worklog, daily at ${HOUR}:00 (loaded)"
echo "  skills      : standup, recall (in $SKILLS)"
echo "  linear      : $( [ -n "$LINEAR_USER_ID" ] && echo "enabled (assignee $EMAIL)" || echo "skipped" )"
say ""
say "Try it now:"
echo "  ~/.claude/worklog/bin/capture.sh          # generate yesterday's entry"
echo "  then ask Claude: \"what's on the go today\" or \"do you remember when we …\""
echo "  backfill history (hours, run detached): see README.md"
