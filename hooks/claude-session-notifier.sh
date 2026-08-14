#!/bin/bash
# Claude Code hook — announce which session finished, or which one is waiting on you.
#
# Registered globally in ~/.claude/settings.json by install.sh on two events, so it
# covers every project and worktree:
#
#   Stop          a turn ended                → "<name> finished"
#   Notification  Claude is waiting on you    → "<name> needs you"
#
# Notification is the one that catches a session blocked on a permission prompt or a
# question, which Stop cannot see: the turn has not ended, so Stop never fires.
#
# Configure with environment variables (export them in ~/.zshrc):
#   CLAUDE_BANNER_SOUND          path to an .aiff, or "none" to stay silent
#   CLAUDE_BANNER_SOUND_WAITING  sound for the waiting case, so you can tell the two
#                                apart without looking
#   CLAUDE_BANNER_DURATION       seconds the banner stays on screen (default 5)
#   CLAUDE_BANNER_TEXT           finished template; %s is the session name
#   CLAUDE_BANNER_TEXT_WAITING   waiting template; %s is the session name
#   CLAUDE_BANNER_NAME_SOURCE    "title" (default) or "folder"

set -uo pipefail

DURATION="${CLAUDE_BANNER_DURATION:-5}"
NAME_SOURCE="${CLAUDE_BANNER_NAME_SOURCE:-title}"

BIN="$HOME/.claude/hooks/bin/claude-banner"

# Read the payload once: `cwd` is always needed, and the title path below needs
# `transcript_path` out of the same stdin.
payload=$(cat)

# `cwd` rather than $CLAUDE_PROJECT_DIR, which is not reliably set for Stop hooks.
cwd=$(printf '%s' "$payload" | jq -r '.cwd // "."' 2>/dev/null || echo ".")
name=$(basename "$cwd")

# Which event are we? Anything that is not Notification is treated as a turn ending, so
# an unfamiliar event degrades to the original behaviour rather than going silent.
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
if [[ "$event" == "Notification" ]]; then
  TEMPLATE="${CLAUDE_BANNER_TEXT_WAITING:-%s needs you}"
  # A different default sound on purpose: "finished" and "blocked on you" want opposite
  # reactions, and the whole point is knowing which without turning to look.
  SOUND="${CLAUDE_BANNER_SOUND_WAITING:-/System/Library/Sounds/Ping.aiff}"
else
  TEMPLATE="${CLAUDE_BANNER_TEXT:-%s finished}"
  SOUND="${CLAUDE_BANNER_SOUND:-/System/Library/Sounds/Glass.aiff}"
fi

# Name the session by Claude's own title. Several sessions in one repo share a folder
# name, which is exactly when knowing which one finished matters most — so the title is
# the more useful default, and `folder` remains available for anyone who would rather
# this hook read nothing but the path it is already handed.
if [[ "$NAME_SOURCE" == "title" ]]; then
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  if [[ -n "$transcript" && -f "$transcript" ]]; then
    # Titles are revised as a session goes on, so the last entry is the current one.
    title=$(grep '"type":"ai-title"' "$transcript" 2>/dev/null | tail -1 \
              | jq -r '.aiTitle // ""' 2>/dev/null || echo "")
    # Sanitised before it is allowed to win: a title is model-generated text, so it is
    # less predictable than a folder name. If nothing survives, the folder name stands
    # rather than degrading to the generic fallback.
    title=$(printf '%s' "$title" | LC_ALL=C tr -d '\000-\037')
    title="${title:0:64}"
    [[ -n "$title" ]] && name="$title"
  fi
fi

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
