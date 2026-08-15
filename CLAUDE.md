# claude-session-notifier — project guide for Claude

A Claude Code hook that draws a banner naming the session that just finished, or the one
blocked waiting on you, so someone running several sessions in parallel knows which one
wants them.

Small on purpose: ~600 lines, MIT, no runtime services. Keep it that way.

## Layout

```
install.sh / uninstall.sh / doctor.sh      macOS entry points
tests/run-tests.sh                         the regression set (CI runs it)
src/banner.swift                           the HUD window (compiled at install time)
hooks/claude-session-notifier.sh           the dispatcher: stdin JSON -> name -> banner
                                           (registered on Stop AND Notification)
docs/why-osascript-fails.md                why Notification Center is avoided
.github/workflows.disabled/ci.yml          CI, parked until the token has `workflow` scope
```

`main` is macOS-only. Windows lives on the **`windows-support`** branch
(`install.ps1`, `uninstall.ps1`, `doctor.ps1`, `src-windows/claude-banner.ps1`,
`hooks/claude-session-notifier.ps1`) and is **unmerged because nobody has run it on
real Windows** — see issue #1. Do not merge it on the strength of CI alone.

## The flow

```
Claude finishes a turn ── or ── blocks waiting on the user
  └─ Stop / Notification hook (~/.claude/settings.json, user scope -> every project)
       └─ claude-session-notifier.sh
            ├─ reads { cwd, transcript_path, hook_event_name } from stdin
            │    ├─ last "ai-title" in the transcript -> "Fix the retry backoff"
            │    └─ or basename of cwd                -> "oz-A"
            ├─ Stop -> "<name> finished"   Notification -> "<name> needs you"
            ├─ afplay Glass.aiff / Ping.aiff  (needs no permission)
            └─ claude-banner "<message>" 5 0 --focus-iterm2 <uuid>
                 └─ borderless NSPanel, .statusBar level, click -> focus that tab
```

Both events are registered because they answer different questions, and a session that
stops to ask something never fires `Stop` — its turn has not ended. `install.sh` and
`uninstall.sh` must stay symmetric across both, or an uninstall leaves half of itself
behind pointing at a deleted script.

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
./uninstall.sh             # remove only our own entries (both events)
./tests/run-tests.sh       # regression set; SKIP_SLOW=1 skips the install round trip

~/.claude/hooks/bin/claude-banner "text" 6 0     # draw directly (message, seconds, slot)
```

## Testing

Exit code 0 proves nothing here — every historical failure exited 0. Two rules:

1. **Test the script, not a copy of its logic.** Point `HOME` at a temp dir containing
   a fake `.claude/hooks/bin/claude-banner` that prints its arguments; feed payloads
   with `jq -n --arg cwd ... '{cwd:$cwd}'`.
2. **Confirm visually.** No automated check can tell whether a window appeared. Draw a
   real banner and ask the user.

`tests/run-tests.sh` implements rule 1 for the whole regression set below; CI runs it.
It clears every `CLAUDE_BANNER_*` and terminal variable before each case, because an
inherited `ITERM_SESSION_ID` from the developer's own shell silently changes what the
hook emits and makes a case pass for the wrong reason.

When adding a test, check it can actually fail: break the line it covers and confirm it
goes red. Doing that found `title="${title:0:64}"` to be dead — the shared cap below it
already applied — so the line was removed rather than the test weakened.

Regression set worth re-running after any change to the dispatcher: plain name, name
with spaces, Hebrew/Japanese/emoji, 90-char name, missing `cwd`, malformed JSON, empty
stdin, `/`, an injection payload, custom `CLAUDE_BANNER_*` vars, and two banners at once.
Since the dispatcher became event-aware and title-aware, add: `hook_event_name` of `Stop`
vs `Notification` vs an unknown value vs absent (all but Notification must read as
"finished", never fall silent), `NAME_SOURCE=title` with a readable transcript, with a
missing one (must fall back to the folder, not the generic label), and `NAME_SOURCE=folder`
never opening the transcript at all. Round-trip `install.sh`/`uninstall.sh` against a
settings.json holding foreign hooks on both events.

## Known limitations (documented in the README — keep them honest)

`Stop` fires every turn end, not just on completion · banner slots are never reclaimed,
and variable heights mean stacked banners leave gaps · main display only · click-to-focus
is iTerm2-only and its first click asks for Automation consent · the visual layer is
untested and untestable · macOS needs `jq` · the `osascript` fallback is unreliable by
design.

## Style

Comments explain *why*, especially where the code looks odd for a security or macOS
reason. The README's honesty about limitations is a feature — don't quietly trim it.
