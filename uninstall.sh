#!/usr/bin/env bash
#
# Remove the Claude Code session-end banner. Leaves the rest of settings.json alone.
#
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT="$CLAUDE_DIR/hooks/claude-session-notifier.sh"
BIN="$CLAUDE_DIR/hooks/bin/claude-banner"
MARKER="claude-session-notifier"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\n  \033[31m✗ %s\033[0m\n\n' "$*" >&2; exit 1; }

printf '\nRemoving claude-session-notifier\n\n'

command -v jq >/dev/null 2>&1 || fail "jq is needed to edit settings.json safely."

if [[ -f "$SETTINGS" ]]; then
  jq empty "$SETTINGS" 2>/dev/null || fail "$SETTINGS is not valid JSON — refusing to touch it."

  BACKUP="$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  ok "backed up settings to $(basename "$BACKUP")"

  TMP="$(mktemp)"
  # Drop only our own entries, then tidy up empty containers we may have created.
  jq --arg marker "$MARKER" '
    if (.hooks.Stop? | type) == "array" then
      .hooks.Stop |= map(
        select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)
      )
      | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$TMP" || fail "failed to edit settings.json (original untouched)"

  mv "$TMP" "$SETTINGS"
  ok "removed Stop hook from settings.json"
fi

rm -f "$SCRIPT" && ok "removed $SCRIPT"
rm -f "$BIN"    && ok "removed $BIN"

printf '\n  Done. Restart running Claude Code sessions to drop the hook.\n\n'
