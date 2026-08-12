# claude-session-notifier

Get told when a Claude Code session finishes — with a banner that says **which** one.

Running Claude in three terminal tabs is great until you lose track of which one is
waiting for you. This installs a `Stop` hook that draws a banner in your top-right
corner naming the folder that just finished, plus a sound.

```
┌────────────────────────────────┐
│  Claude Code                   │
│  oz-A finished                 │
└────────────────────────────────┘
```

> **v0.1** — works, but young. It was extracted from a working setup on one Mac
> (macOS 26.5.2, Apple Silicon) and has not been tested widely. Please read
> [Known limitations](#known-limitations) before relying on it.

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
| Xcode Command Line Tools | for `swiftc` — `xcode-select --install` |
| [`jq`](https://jqlang.github.io/jq/) | to parse the hook payload — `brew install jq` |

`install.sh` checks all four and stops with the exact fix if one is missing.

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

**Your settings are merged, not overwritten.** Existing `Stop` hooks are preserved,
`settings.json` is backed up first, and re-running updates in place rather than
registering a duplicate.

## Uninstall

```bash
./uninstall.sh
```

Removes only its own hook entry, backing up `settings.json` first.

## Configuration

Environment variables, e.g. in `~/.zshrc`:

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_BANNER_SOUND` | `/System/Library/Sounds/Glass.aiff` | any `.aiff`, or `none` for silence |
| `CLAUDE_BANNER_DURATION` | `5` | seconds on screen |
| `CLAUDE_BANNER_TEXT` | `%s finished` | `%s` becomes the folder name |

```bash
export CLAUDE_BANNER_TEXT="🎉 %s is done!"
export CLAUDE_BANNER_DURATION=8
```

## How it works

```
Claude finishes a turn
  └─ Stop hook  (~/.claude/settings.json, user scope → every project)
       └─ claude-session-notifier.sh
            ├─ reads { "cwd": ... } from stdin  →  basename  →  "oz-A"
            ├─ afplay Glass.aiff                    (needs no permission)
            └─ claude-banner "oz-A finished" 5 0
                 └─ borderless NSWindow, .statusBar level, click-through
```

The session name comes from `cwd` in the hook's stdin payload, **not**
`$CLAUDE_PROJECT_DIR` — that variable is not reliably set for `Stop` hooks.

The binary is compiled on your machine on purpose. A downloaded binary would be
Gatekeeper-quarantined and refuse to run without notarization.

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

## Known limitations

Honest list. These are real and unfixed in v0.1.

- **`Stop` fires on every turn end, not just task completion.** A session that stops
  to ask you a question also rings. Usually what you want when babysitting several
  sessions — but it is chattier than a single "all done" ping.
- **Banner slots are not reclaimed.** Position is chosen by counting running banner
  processes. If several sessions finish in a staggered pattern, a banner can be
  placed lower than necessary, and with enough of them one can be drawn off-screen.
  A lockfile-based coordinator would fix this.
- **Main display only.** Always draws on `NSScreen.main`. On a multi-monitor setup it
  may not be on the screen you are looking at.
- **Tested on exactly one machine.** macOS 26.5.2, Apple Silicon, iTerm2, zsh. Older
  macOS and Intel Macs are unverified — reports welcome.
- **Long messages clip.** The window is a fixed 380×92 with no auto-sizing.
- **No tests.** CI only checks that the Swift compiles.
- **`jq` dependency in the hook path.** Could be folded into the Swift binary to make
  the tool dependency-free. Not done yet.
- **The `osascript` fallback is unreliable by design.** If the binary is missing, the
  script falls back to the very mechanism this project exists to avoid. It is there
  so something is attempted, not because it works.

## Contributing

Issues and PRs welcome — especially reports from other macOS versions and hardware,
since single-machine testing is this release's weakest point.

## Credits

Thank you Asaf Ambar for being part of the idea and thinking how to create it together.

## License

MIT — see [LICENSE](LICENSE).
