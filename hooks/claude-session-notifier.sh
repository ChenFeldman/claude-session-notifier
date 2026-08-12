#!/bin/bash
# Claude Code Stop hook — announce which session just finished a turn.
#
# Registered globally in ~/.claude/settings.json by install.sh, so it covers every
# project and worktree. Claude Code sends the hook a JSON payload on stdin; `cwd`
# is what tells us WHICH session finished.
#
# Configure with environment variables (export them in ~/.zshrc):
#   CLAUDE_BANNER_SOUND     path to an .aiff, or "none" to stay silent
#   CLAUDE_BANNER_DURATION  seconds the banner stays on screen (default 5)
#   CLAUDE_BANNER_TEXT      message template; %s is replaced with the folder name

set -uo pipefail

SOUND="${CLAUDE_BANNER_SOUND:-/System/Library/Sounds/Glass.aiff}"
DURATION="${CLAUDE_BANNER_DURATION:-5}"
TEMPLATE="${CLAUDE_BANNER_TEXT:-%s finished}"

BIN="$HOME/.claude/hooks/bin/claude-banner"

# `cwd` arrives as JSON on stdin. We use it rather than $CLAUDE_PROJECT_DIR, which
# is not reliably set for Stop hooks.
cwd=$(cat | jq -r '.cwd // "."' 2>/dev/null || echo ".")
name=$(basename "$cwd")

# The folder name is untrusted input: it can come from a branch name (via
# `git worktree add`), and on the osascript fallback path it would otherwise be
# interpolated into an AppleScript string, where a crafted name could break out and
# run commands. Allow only benign characters and cap the length.
name=$(printf '%s' "$name" | LC_ALL=C tr -c 'A-Za-z0-9._ -' '_' | cut -c1-64)
[[ -z "$name" ]] && name="claude"

# Plain string substitution rather than printf: the template is user-supplied, and
# treating it as a format string invites surprises for no benefit.
message="${TEMPLATE//%s/$name}"

# Audible signal first: it needs no notification permission, so it works even if
# the visual path is broken.
if [[ "$SOUND" != "none" && -f "$SOUND" ]]; then
  afplay "$SOUND" 2>/dev/null &
fi

if [[ -x "$BIN" ]]; then
  # Stack below any banner already on screen so parallel sessions don't overlap.
  # Known limitation: slots are not reclaimed as banners fade — see README.
  slot=$(pgrep -x claude-banner 2>/dev/null | wc -l | tr -d ' ')
  "$BIN" "$message" "$DURATION" "$slot"
else
  # Fallback if the binary is missing. Note this path is unreliable: macOS may
  # discard the notification while osascript still exits 0.
  osascript -e "display notification \"$message\" with title \"Claude Code\"" 2>/dev/null
fi
