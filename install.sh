#!/usr/bin/env bash
#
# Install the Claude Code session-end banner.
#
#   ./install.sh            install or update
#   ./install.sh --dry-run  show what would change, touch nothing
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
BIN_DIR="$HOOKS_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DEST="$HOOKS_DIR/claude-session-banner.sh"
HOOK_CMD="bash $SCRIPT_DEST"
MARKER="claude-session-banner"     # how we recognise our own hook entry

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
fail() { printf '\n  \033[31m✗ %s\033[0m\n\n' "$*" >&2; exit 1; }

printf '\nClaude Code session banner\n\n'

# ── Preflight ────────────────────────────────────────────────────────────────
# Fail loudly here. A missing dependency that only shows up at runtime produces a
# hook that silently does nothing, which is painful to debug.

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only (this uses AppKit and afplay)."

command -v swiftc >/dev/null 2>&1 || fail \
"swiftc not found. Install the Xcode Command Line Tools:

    xcode-select --install"

command -v jq >/dev/null 2>&1 || fail \
"jq not found. Install it with:

    brew install jq"

[[ -d "$CLAUDE_DIR" ]] || fail \
"$CLAUDE_DIR not found. Install Claude Code first:

    https://claude.com/claude-code"

ok "macOS $(sw_vers -productVersion)"
ok "swiftc $(swiftc --version 2>/dev/null | head -1 | sed 's/.*Swift version \([0-9.]*\).*/\1/')"
ok "jq $(jq --version | sed 's/jq-//')"
ok "found $CLAUDE_DIR"

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n  Dry run — would then:\n'
  info "compile  $REPO_DIR/src/banner.swift  ->  $BIN_DIR/claude-banner"
  info "install  $SCRIPT_DEST"
  info "register a Stop hook in $SETTINGS (backing it up first)"
  printf '\n'
  exit 0
fi

# ── Build ────────────────────────────────────────────────────────────────────
# Compiled on your machine on purpose: a downloaded binary would be quarantined by
# Gatekeeper and refuse to run without notarization.

mkdir -p "$BIN_DIR"
swiftc -O -o "$BIN_DIR/claude-banner" "$REPO_DIR/src/banner.swift" \
  || fail "compile failed — please open an issue with the output above."
ok "compiled $BIN_DIR/claude-banner"

install -m 0755 "$REPO_DIR/hooks/claude-session-banner.sh" "$SCRIPT_DEST"
ok "installed $SCRIPT_DEST"

# ── Register the hook ────────────────────────────────────────────────────────
# Merge, never overwrite: you may already have Stop hooks, and clobbering someone's
# settings.json is unforgivable. Any previous entry of OURS is dropped first, so
# re-running updates in place instead of registering a duplicate.

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

jq empty "$SETTINGS" 2>/dev/null || fail \
"$SETTINGS is not valid JSON. Fix or move it first — refusing to touch it."

BACKUP="$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
ok "backed up settings to $(basename "$BACKUP")"

TMP="$(mktemp)"
jq --arg cmd "$HOOK_CMD" --arg marker "$MARKER" '
  .hooks //= {}
  | .hooks.Stop //= []
  | .hooks.Stop |= map(
      select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)
    )
  | .hooks.Stop += [{ hooks: [{ type: "command", command: $cmd, async: true }] }]
' "$SETTINGS" > "$TMP" || fail "failed to update settings.json (original untouched)"

mv "$TMP" "$SETTINGS"
ok "registered Stop hook in settings.json"

# ── Verify ───────────────────────────────────────────────────────────────────
# End on proof, not a promise. If no banner appears, you find out now.

echo '{"cwd":"'"$PWD"'"}' | bash "$SCRIPT_DEST" || true

cat <<EOF

  Done. A test banner should have appeared in your top-right corner.

  If you saw it, you're set: every Claude Code session on this Mac will now
  announce itself when it finishes a turn, labelled with its folder name.

  If you did NOT see it, run ./doctor.sh — it will tell you which stage failed.

  Restart any Claude Code sessions that are already running, or open /hooks
  once, so they pick up the new configuration.

EOF
