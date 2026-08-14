# claude-session-notifier — project guide for Claude

A Claude Code `Stop` hook that draws a banner naming the session that just finished,
so someone running several sessions in parallel knows which one wants them.

Small on purpose: ~600 lines, MIT, no runtime services. Keep it that way.

## Layout

```
install.sh / uninstall.sh / doctor.sh      macOS entry points
src/banner.swift                           the HUD window (compiled at install time)
hooks/claude-session-notifier.sh           the dispatcher: stdin JSON -> name -> banner
docs/why-osascript-fails.md                why Notification Center is avoided
.github/workflows.disabled/ci.yml          CI, parked until the token has `workflow` scope
```

`main` is macOS-only. Windows lives on the **`windows-support`** branch
(`install.ps1`, `uninstall.ps1`, `doctor.ps1`, `src-windows/claude-banner.ps1`,
`hooks/claude-session-notifier.ps1`) and is **unmerged because nobody has run it on
real Windows** — see issue #1. Do not merge it on the strength of CI alone.

## The flow

```
Claude finishes a turn
  └─ Stop hook (~/.claude/settings.json, user scope -> every project)
       └─ claude-session-notifier.sh
            ├─ reads { "cwd": ... } from stdin -> basename -> "oz-A"
            ├─ afplay Glass.aiff              (needs no permission)
            └─ claude-banner "oz-A finished" 5 0
                 └─ borderless NSWindow, .statusBar level, click-through
```

## Invariants — do not break these

- **Never route through Notification Center or Windows toasts.** `osascript` posts as
  Script Editor and macOS silently discards it (exit 0, nothing shown); Windows toasts
  need an AUMID and fail the same way. The whole project exists because of this. Draw
  our own window.
- **Escape at the point of use, never sanitize the name globally.** The folder name is
  untrusted (branch names reach directory names via `git worktree add`, and branch
  names come from PRs). The banner takes text through `argv` where nothing is special;
  only the `osascript` / `Start-Process` paths escape, immediately before use.
  A previous global filter broke every non-ASCII folder name — see the commit
  "Fix two regressions from the sanitizing commit".
- **Unicode folder names must render.** Hebrew, Japanese, emoji. Regression-test them.
- **Read `cwd` from stdin, not `$CLAUDE_PROJECT_DIR`** — that variable is not reliably
  set for `Stop` hooks.
- **Merge `settings.json`, never overwrite.** Back it up, drop only entries matching the
  `claude-session-notifier` marker, stay idempotent on re-run.
- **Compile on the user's machine.** A downloaded binary is Gatekeeper-quarantined.
- **No network calls. Nothing is ever written or logged.** The hook reads `cwd` and, when
  `CLAUDE_BANNER_NAME_SOURCE=title` (the default), the last `ai-title` entry out of
  `transcript_path`. Nothing else in the payload is touched — not `session_id`, not
  `last_assistant_message`. Widening that set is a decision, not a refactor.
- **`folder` must stay a real escape hatch.** Someone who sets it is asking this hook to
  read nothing but the path it is handed. Keep that path free of transcript access.
- **Validate the tab id, and never splice it into script text.** It comes from an
  environment variable, so hook and binary both check it against hex-and-dashes, and it
  reaches `osascript` through `argv`. Same discipline as the session name.
- **No focus target means click-through.** The banner must not start intercepting clicks
  for people it cannot help.

## Commands

```bash
./install.sh --dry-run     # show what would change
./install.sh               # compile, install, register, fire a test banner
./doctor.sh                # isolate which stage failed
./uninstall.sh             # remove only our own entry

~/.claude/hooks/bin/claude-banner "text" 6 0     # draw directly (message, seconds, slot)
```

## Testing

Exit code 0 proves nothing here — every historical failure exited 0. Two rules:

1. **Test the script, not a copy of its logic.** Point `HOME` at a temp dir containing
   a fake `.claude/hooks/bin/claude-banner` that prints its arguments; feed payloads
   with `jq -n --arg cwd ... '{cwd:$cwd}'`.
2. **Confirm visually.** No automated check can tell whether a window appeared. Draw a
   real banner and ask the user.

Regression set worth re-running after any change to the dispatcher: plain name, name
with spaces, Hebrew/Japanese/emoji, 90-char name, missing `cwd`, malformed JSON, empty
stdin, `/`, an injection payload, custom `CLAUDE_BANNER_*` vars, and two banners at once.

## Known limitations (documented in the README — keep them honest)

`Stop` fires every turn end, not just on completion · banner slots are never reclaimed ·
main display only · fixed 380×92 window clips long text · no unit tests · macOS needs
`jq` · the `osascript` fallback is unreliable by design.

## Style

Comments explain *why*, especially where the code looks odd for a security or macOS
reason. The README's honesty about limitations is a feature — don't quietly trim it.
