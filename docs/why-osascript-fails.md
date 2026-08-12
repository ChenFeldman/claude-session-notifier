# Why `osascript` notifications silently fail

A short field report, written because every failing approach here returns **exit code
0**. There is no error to search for — only an absence — which makes this
disproportionately expensive to debug.

## The symptom

```bash
osascript -e 'display notification "done" with title "Claude"'
echo $?   # 0
```

Exit 0. Nothing on screen. Nothing in Notification Center.

## The cause

`display notification` does not post as your terminal. AppleScript run via
`osascript` is attributed to **Script Editor**. If Script Editor has never been
granted notification authorization — which is normal on a Mac where nobody has opened
it — macOS discards the post.

The discard is silent. `osascript` has successfully handed the message to the system;
what the system then does with it is not reflected in the exit code.

## Why `terminal-notifier` isn't automatically the fix

`terminal-notifier` ships its own app bundle, so it gets its own identity and a real
permission prompt. That solves *delivery*:

```bash
terminal-notifier -list ALL
# GroupID          Title         Message           Delivered At
# claude-oz-A      Claude Code   oz-A finished     2026-08-12 12:41:29 +0000
```

**This command is the key diagnostic.** It shows what macOS actually accepted, which
separates two states that look identical from the exit code:

- not delivered — the message never reached Notification Center
- delivered but not drawn — it is in the tray, but no banner was shown

If your message appears in `-list ALL` and you still saw no banner, the problem is
alert style, not delivery.

## Why you can't fix alert style from a script

Alert style (Banners vs Alerts vs None) lives in `com.apple.ncprefs`, which is
TCC-protected on modern macOS. You cannot reliably read it and you cannot write it:

```bash
defaults read com.apple.ncprefs        # empty or denied
plutil -convert xml1 -o - ~/Library/Preferences/com.apple.ncprefs.plist
# Invalid file
```

Apple blocks this deliberately — an app that could set its own notification
prominence would abuse it. So any tool routing through Notification Center depends on
a toggle only the user can flip, in System Settings → Notifications.

## The approach that avoids the problem

Draw your own window. Notification Center is never involved, so none of the above
applies:

```swift
window.level = .statusBar                  // above normal windows
window.ignoresMouseEvents = true           // click-through
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
app.setActivationPolicy(.accessory)        // no Dock icon
```

Trade-offs, stated plainly: you lose Notification Center history, Focus-mode
integration, and the system's own stacking behaviour. In exchange the thing actually
appears, on any Mac, with no setup.

## Debugging checklist

If a notification hook seems dead, establish these in order — each isolates a
different stage:

1. **Is the hook firing at all?** Append to a log file from inside the hook. Without
   this you cannot tell "hook never ran" from "hook ran, nothing displayed".
2. **Is a dependency missing?** A hook calling `jq` on a Mac without `jq` fails
   quietly mid-pipeline.
3. **Was the message delivered?** `terminal-notifier -list ALL`.
4. **Is Focus on?** Check `~/Library/DoNotDisturb/DB/Assertions.json`. Affects sound
   and banners, not delivery.
5. **Can anything draw at all?** Run the banner binary directly. If that works, the
   problem is upstream in the hook, not in the display path.
