#!/usr/bin/env bash
#
# Diagnose a banner that isn't appearing.
#
# The failure modes here are unusually quiet — the common ones all exit 0 — so this
# walks the pipeline stage by stage and reports where it actually stops.
#
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT="$CLAUDE_DIR/hooks/claude-session-notifier.sh"
BIN="$CLAUDE_DIR/hooks/bin/claude-banner"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

printf '\nclaude-session-notifier — doctor\n\n'

# 1. Dependencies
command -v jq     >/dev/null 2>&1 && pass "jq present" || bad "jq missing → brew install jq"
command -v afplay >/dev/null 2>&1 && pass "afplay present" || warn "afplay missing (sound disabled)"

# 2. Installed files
[[ -x "$BIN" ]]    && pass "binary installed"  || bad "binary missing → ./install.sh"
[[ -x "$SCRIPT" ]] && pass "hook script installed" || bad "hook script missing → ./install.sh"

# 3. Hook registration — both events, reported separately. Stop alone is a working
#    install that stays silent whenever a session is blocked asking you something.
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
  for event in Stop Notification; do
    count=$(jq --arg e "$event" \
      '[.hooks[$e][]?.hooks[]?.command | select(test("claude-session-notifier"))] | length' \
      "$SETTINGS" 2>/dev/null || echo 0)
    if [[ "${count:-0}" -ge 1 ]]; then
      pass "$event hook registered in settings.json"
    elif [[ "$event" == "Notification" ]]; then
      warn "$event hook NOT registered — no banner when a session is waiting on you → ./install.sh"
    else
      bad "$event hook NOT registered → ./install.sh"
    fi
    [[ "${count:-0}" -gt 1 ]] && warn "$event registered $count times — you will get duplicate banners"
  done
else
  bad "cannot read $SETTINGS"
fi

# 4. Which name will the banner use, and can it actually get it?
NAME_SOURCE="${CLAUDE_BANNER_NAME_SOURCE:-title}"
pass "name source: $NAME_SOURCE"
if [[ "$NAME_SOURCE" == "title" ]]; then
  latest=$(ls -t "$CLAUDE_DIR"/projects/*/*.jsonl 2>/dev/null | head -1)
  if [[ -n "$latest" ]] && grep -q '"type":"ai-title"' "$latest" 2>/dev/null; then
    pass "session titles readable (e.g. \"$(grep '"type":"ai-title"' "$latest" | tail -1 | jq -r '.aiTitle' 2>/dev/null)\")"
  else
    warn "no session title found yet — banners will fall back to the folder name"
  fi
fi

# 5. Click-to-focus needs a resolvable tab id; without one the banner is inert but fine.
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]]; then
  pass "click-to-focus available (iTerm2 session ${ITERM_SESSION_ID#*:})"
  printf '    note: the first click asks for Automation permission; denying it\n'
  printf '    downgrades the click to activating iTerm2 without selecting the tab.\n'
else
  warn "click-to-focus unavailable here (needs iTerm2; TERM_PROGRAM=${TERM_PROGRAM:-unset})"
fi

# 4. Does the binary actually draw?
if [[ -x "$BIN" ]]; then
  printf '\n  Drawing a test banner (top-right, 4s)...\n'
  "$BIN" "doctor test — if you can read this, the banner works" 4
  printf '  Did it appear? If YES, the binary is fine and the problem is upstream\n'
  printf '  (hook not firing). If NO, please open an issue with your macOS version.\n'
fi

# 5. Focus / Do Not Disturb — affects the sound, not the banner
if [[ -s "$HOME/Library/DoNotDisturb/DB/Assertions.json" ]]; then
  warn "a Focus mode may be active (this can silence the sound; the banner still draws)"
fi

printf '\n  Note: the banner does not use Notification Center, so notification\n'
printf '  permissions and alert-style settings are irrelevant to it.\n\n'
