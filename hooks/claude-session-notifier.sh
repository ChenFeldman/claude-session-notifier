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
# Control characters are stripped (they garble the display) and the length is capped.
# Unicode is preserved deliberately: folder names in Hebrew, Japanese, or with emoji
# are legitimate, and replacing them with underscores made the banner useless for
# anyone not working in ASCII. Injection is prevented where it actually matters — the
# osascript call below escapes at the point of use, and the banner binary receives its
# text through argv, where no character is special.
name=$(printf '%s' "$name" | LC_ALL=C tr -d '\000-\037')
name="${name:0:64}"
# "." and "/" both mean we never got a usable path.
[[ -z "$name" || "$name" == "." || "$name" == "/" ]] && name="claude"

# Plain string substitution rather than printf: the template is user-supplied, and
# treating it as a format string invites surprises for no benefit.
message="${TEMPLATE//%s/$name}"

# Audible signal first: it needs no notification permission, so it works even if
# the visual path is broken.
if [[ "$SOUND" != "none" && -f "$SOUND" ]]; then
  afplay "$SOUND" 2>/dev/null &
fi

# Click-to-focus: work out which tab this session is in, so clicking the banner can
# jump back to it.
#
# iTerm2 exports ITERM_SESSION_ID and it is inherited all the way down into this hook.
# Only the uuid after the "wNtNpN:" prefix is usable: those coordinates are fixed when
# the session is created and go stale as soon as tabs are reordered or closed.
#
# The tty would work as a second handle, but it needs an ancestry walk — Claude Code
# spawns hooks with no controlling terminal, so `ps -o tty= -p $$` here reports "??".
FOCUS_ARGS=()
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]]; then
  session_uuid="${ITERM_SESSION_ID#*:}"
  # SECURITY: validated before it can reach AppleScript. Hex and dashes only, so there
  # is no string to break out of downstream. A non-matching value is simply dropped and
  # the banner stays click-through.
  if [[ "$session_uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    FOCUS_ARGS=(--focus-iterm2 "$session_uuid")
  fi
fi

if [[ -x "$BIN" ]]; then
  # Stack below any banner already on screen so parallel sessions don't overlap.
  # Known limitation: slots are not reclaimed as banners fade — see README.
  slot=$(pgrep -x claude-banner 2>/dev/null | wc -l | tr -d ' ')
  # ${a[@]+"${a[@]}"} not "${a[@]}": macOS ships bash 3.2, where an empty array under
  # `set -u` is treated as unbound and aborts the hook.
  "$BIN" "$message" "$DURATION" "$slot" ${FOCUS_ARGS[@]+"${FOCUS_ARGS[@]}"}
else
  # Fallback if the binary is missing. Note this path is unreliable: macOS may
  # discard the notification while osascript still exits 0.
  #
  # SECURITY: this is the one place the message is interpolated into a language that
  # can execute commands, so escape it here at the point of use. Backslash first, then
  # double quote — reversing the order would double-escape. Without this, a folder
  # named  evil" & (do shell script "...") & "x  would break out of the string.
  escaped=${message//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  osascript -e "display notification \"$escaped\" with title \"Claude Code\"" 2>/dev/null
fi
