# claude-session-notifier

Get told when a Claude Code session finishes — or needs you — with a banner that says
**which** one.

Running Claude in three terminal tabs is great until you lose track of which one is
waiting for you. This installs hooks that draw a banner in your top-right corner naming
the session that just finished — or the one blocked on a question — plus a sound. Click
the banner and it takes you straight to the tab it came from.

```
┌──────────────────────────────────┐
│  ✳   Claude Code · click to focus│
│      Fix the retry backoff       │
└──────────────────────────────────┘
```

The icon is the installed Claude app's own, read at runtime — nothing is bundled here.

> **v0.1** — works, but young. It was extracted from a working setup on one Mac
> (macOS 26.5.2, Apple Silicon) and has not been tested widely. Please read
> [Known limitations](#known-limitations) before relying on it.
>
> **Windows?** An implementation exists on the
> [`windows-support`](https://github.com/ChenFeldman/claude-session-notifier/tree/windows-support)
> branch but has never been run on a real Windows machine, so it is not merged.
> If you can test it, [issue #1](https://github.com/ChenFeldman/claude-session-notifier/issues/1)
> is the one thing blocking it.

## Why not just use `osascript`?

Nearly every "notify me when Claude finishes" snippet uses this:

```bash
osascript -e 'display notification "done" with title "Claude"'
```

On many Macs **that command exits 0 and displays nothing.** `osascript` posts under
Script Editor's identity, and if Script Editor has no notification authorization,
macOS discards the message without an error. There is nothing to debug — just
silence.

`terminal-notifier` gets further (macOS genuinely accepts the message) but still only
draws a banner if that app's alert style permits it, and you cannot set that from a
script — `com.apple.ncprefs` is TCC-protected.

So this tool **skips Notification Center entirely** and draws its own window. No
authorization, no alert-style toggle, nothing to click in System Settings. See
[docs/why-osascript-fails.md](docs/why-osascript-fails.md) for the full write-up and
the diagnostic that distinguishes "not delivered" from "delivered but not drawn".

## Requirements

| | |
|---|---|
| macOS | uses AppKit + `afplay`. No Linux/Windows support. |
| [Claude Code](https://claude.com/claude-code) | must be installed (`~/.claude` must exist) |
| Claude desktop app | *optional* — its icon is borrowed for the banner. Without it you get an SF Symbol instead. |
| Xcode Command Line Tools | for `swiftc` — `xcode-select --install` |
| [`jq`](https://jqlang.github.io/jq/) | to parse the hook payload — `brew install jq` |

`install.sh` checks each of these and stops with the exact fix if one is missing.

## Install

```bash
git clone https://github.com/ChenFeldman/claude-session-notifier.git
cd claude-session-notifier
./install.sh
```

The installer compiles the banner, installs the hook script, registers it in
`~/.claude/settings.json`, and fires a test banner so you know immediately whether it
works. Use `./install.sh --dry-run` to see what it would do first.

Already-running Claude sessions need a restart (or open `/hooks` once) to pick it up.

**Your settings are merged, not overwritten.** Existing `Stop` and `Notification` hooks
are preserved, `settings.json` is backed up first, and re-running updates in place rather
than registering a duplicate.

## Uninstall

```bash
./uninstall.sh
```

Removes only its own entries — from both events — backing up `settings.json` first.

## Configuration

Environment variables, e.g. in `~/.zshrc`:

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_BANNER_SOUND` | `/System/Library/Sounds/Glass.aiff` | any `.aiff`, or `none` for silence |
| `CLAUDE_BANNER_SOUND_WAITING` | `/System/Library/Sounds/Ping.aiff` | sound when a session is waiting on you |
| `CLAUDE_BANNER_DURATION` | `5` | seconds on screen |
| `CLAUDE_BANNER_TEXT` | `%s finished` | `%s` becomes the session name |
| `CLAUDE_BANNER_TEXT_WAITING` | `%s needs you` | shown when a session is blocked on you |
| `CLAUDE_BANNER_NAME_SOURCE` | `folder` | `folder` for the directory name, `title` for Claude's own session title |

```bash
export CLAUDE_BANNER_TEXT="🎉 %s is done!"
export CLAUDE_BANNER_DURATION=8
export CLAUDE_BANNER_NAME_SOURCE=folder
```

### Which name you get

`folder`, the default, uses the directory name. The hook reads nothing but the path it is
already handed, and the label is short and stable for the whole session.

`title` uses the session title Claude generates — "Fix the retry backoff" — which is what
distinguishes three sessions running in the *same* repo, the case this tool exists for. It
comes from the transcript Claude Code already writes; nothing is generated or requested for
it. It is opt-in because it puts a description of your work on screen, and because it means
this hook reads a file rather than just a path:

```bash
export CLAUDE_BANNER_NAME_SOURCE=title
```

Titles run longer than folder names, so the banner sizes its height to the text rather
than truncating it. If the title cannot be read — early in a session, before Claude has
named it — the folder name is used instead.

## How it works

Two events are registered, because they answer different questions:

| Event | Fires when | Banner says |
|---|---|---|
| `Stop` | a turn ended | `<name> finished` |
| `Notification` | Claude is blocked on you — permission prompt or question | `<name> needs you` |

`Notification` matters more than it sounds. A session that stops to ask you something has
**not** ended its turn, so `Stop` never fires and the old behaviour was silence at exactly
the moment you were being waited on. The two cases get different default sounds so you can
tell them apart without turning to look.

That event also fires about a minute after the prompt goes quiet (`notification_type` of
`idle_prompt`), which happens after every turn you walk away from. Those are ignored — they
mean "you stopped typing", not "I am blocked", and ringing for them would follow every
*finished* with a spurious *needs you*. An unrecognised type still rings, so a new kind of
attention request is never silently dropped.

```
Claude finishes a turn ── or ── blocks waiting on you
  └─ Stop / Notification hook  (~/.claude/settings.json, user scope → every project)
       └─ claude-session-notifier.sh
            ├─ reads { cwd, transcript_path, hook_event_name } from stdin
            │    ├─ last "ai-title" in the transcript  →  "Fix the retry backoff"
            │    └─ or basename of cwd                 →  "oz-A"
            ├─ resolves the tab from $ITERM_SESSION_ID  (iTerm2 only)
            ├─ afplay Glass.aiff / Ping.aiff        (needs no permission)
            └─ claude-banner "Fix the retry backoff" 5 0 --focus-iterm2 <uuid>
                 └─ borderless NSPanel, .statusBar level, click → focus that tab
```

Paths come from the stdin payload, **not** `$CLAUDE_PROJECT_DIR` — that variable is not
reliably set for `Stop` hooks.

The binary is compiled on your machine on purpose. A downloaded binary would be
Gatekeeper-quarantined and refuse to run without notarization.

### Click to focus

The banner knows which tab produced it, so clicking it takes you there.

iTerm2 exports `ITERM_SESSION_ID`, and that variable is inherited all the way down into
the hook — so the session that finished can be matched against iTerm2's own session id
and selected. Only the uuid is used; the `wNtNpN` coordinates in that variable are fixed
when the session is created and go stale the moment tabs are reordered.

| | Focus the app | Focus the exact tab |
|---|---|---|
| iTerm2 | ✓ | ✓ |
| Terminal.app, WezTerm, tmux | ✓ | not yet implemented |
| Ghostty, VS Code, IntelliJ | ✓ | not possible — no scripting hook for it |

Selecting a tab goes through AppleScript, so macOS asks for Automation permission the
first time you click. Deny it and the click still activates the app — right window, wrong
tab — because plain activation needs no permission. **The banner itself never needs
permission either way**; only the click's precision does.

Where no tab can be resolved the banner stays click-through, exactly as it was before.

## Not working?

```bash
./doctor.sh
```

It walks the pipeline stage by stage and reports where it stops — dependencies,
installed files, hook registration, and whether the binary can draw at all.

## Alternatives

**[cmux](https://cmux.com)** solves the same problem far more thoroughly: a native
macOS terminal built for running coding agents in parallel, with a workspace sidebar,
git branch and PR status per session, an embedded browser, a socket API, and
notification rings when an agent needs you. Open source (GPL-3.0, with a commercial
license available).

The difference is what you give up to get it. cmux is a terminal you **switch to**;
this is a hook you **add** to the terminal you already use. If you're open to changing
terminals, cmux will serve you better than this ever will — go use it.

This exists for the other case: you like iTerm2 (or Terminal, Ghostty, WezTerm, tmux)
and want one specific thing — to know which session just finished — without replacing
your setup to get it. It's ~600 lines, MIT, touches one config file, and
`./uninstall.sh` removes it completely.

[docs/why-osascript-fails.md](docs/why-osascript-fails.md) is useful either way: it
applies to any macOS notification hook, whatever tool you end up using.

Thank you Ido Koren for giving the cmux feedback.

## Security

What this code does and doesn't do, so you can judge it rather than trust it:

- **No network access.** Nothing here makes a request. Nothing phones home.
- **Nothing is downloaded at install time.** The macOS binary is compiled from the
  source in this repo, on your machine.
- **Nothing is logged.** Nothing is written anywhere, ever. Values are read, used to
  draw one banner, and discarded when the process exits.
- **It reads your session transcript, by default.** With `CLAUDE_BANNER_NAME_SOURCE=title`
  — the default — the hook opens the `transcript_path` it is given and pulls out the last
  `ai-title` entry. That is one field of one line of a file Claude Code already wrote on
  your disk; conversation content is not read, nothing is sent anywhere, and nothing is
  stored. If you would rather this hook touch nothing but the directory path it is handed,
  set `CLAUDE_BANNER_NAME_SOURCE=folder`.
- **The only file modified outside its own directory is `~/.claude/settings.json`**,
  which is backed up before every change, and `./uninstall.sh` reverses.
- **The session name is treated as untrusted, whichever source it comes from.** A folder
  name can be attacker-influenced — `git worktree add` derives a directory name from a
  branch name, and branch names come from pull requests. A title is model-generated text,
  so it is unpredictable for different reasons. Both get control characters stripped and
  are capped at 64 characters, and both reach the banner through `argv`, where no
  character is special. Without that, a directory named
  `evil" & (do shell script "...") & "x` would inject into the AppleScript fallback path
  on macOS, and into the process arguments on Windows. Both were real and are fixed; see
  [#2](../../issues/2).
- **The tab id is validated to hex and dashes before use.** It traces back to an
  environment variable, so it is checked in both the hook and the binary, and it reaches
  `osascript` as an argument rather than spliced into the script text — there is no string
  for it to break out of.

If you find something, please open an issue.

## Known limitations

Honest list. These are real and unfixed in v0.1.

- **`Stop` fires on every turn end, not just task completion.** Usually what you want when
  babysitting several sessions — but it is chattier than a single "all done" ping. A session
  that stops to ask you something now rings via `Notification` instead, with its own wording
  and sound.
- **Banner slots are not reclaimed.** Position is chosen by counting running banner
  processes. If several sessions finish in a staggered pattern, a banner can be
  placed lower than necessary, and with enough of them one can be drawn off-screen.
  A lockfile-based coordinator would fix this.
- **Main display only.** Always draws on `NSScreen.main`. On a multi-monitor setup it
  may not be on the screen you are looking at.
- **Tested on exactly one machine.** macOS 26.5.2, Apple Silicon, iTerm2, zsh. Older
  macOS and Intel Macs are unverified — reports welcome.
- **Stacked banners leave gaps.** Height now follows the text, so the stacking pitch has
  to assume the tallest possible banner or a tall one would draw over a short one. Short
  banners therefore sit further apart than they need to. Cosmetic, and the same lockfile
  coordinator that would fix slot reclamation would fix this too.
- **Click-to-focus is iTerm2 only.** Everywhere else the banner stays click-through.
  Terminal.app, WezTerm and tmux are all scriptable enough to support — nobody has
  written it yet. Ghostty, VS Code and IntelliJ cannot select a specific tab at all.
- **The first click asks for Automation permission.** Unavoidable for tab selection.
  Denying it downgrades the click to activating the app, which needs no permission.
- **Titles lag at the start of a session.** With `CLAUDE_BANNER_NAME_SOURCE=title`, Claude
  has not named the session yet in the first moments, so early banners fall back to the
  folder name.
- **The visual layer has no automated tests.** `./tests/run-tests.sh` covers the
  dispatcher — naming, events, fallbacks, injection, the install/uninstall round trip —
  but no check can assert that a window actually appeared, that a click landed on the
  right tab, or that the sound played. Those still need a person and `./install.sh`.
- **`jq` dependency in the hook path.** Could be folded into the Swift binary to make
  the tool dependency-free. Not done yet.
- **The `osascript` fallback is unreliable by design.** If the binary is missing, the
  script falls back to the very mechanism this project exists to avoid. It is there
  so something is attempted, not because it works.

## Contributing

Issues and PRs welcome — especially reports from other macOS versions and hardware,
since single-machine testing is this release's weakest point.

If you are changing the dispatcher, turn on the pre-commit hook once per clone:

```bash
git config core.hooksPath .githooks
```

It runs `SKIP_SLOW=1 ./tests/run-tests.sh` when you stage anything under `hooks/`,
`src/`, `tests/`, or the top-level scripts, and stays out of the way otherwise. It is a
convenience, not a gate — CI runs the full set including the install round trip, and
neither can tell you whether a banner actually appeared on screen.

## Credits

Thank you Asaf Ambar for being part of the idea and thinking how to create it together.

## License

MIT — see [LICENSE](LICENSE).
