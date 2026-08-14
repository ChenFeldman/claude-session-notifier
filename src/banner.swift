import Cocoa

// A borderless HUD that appears in the top-right corner and fades out.
//
// Deliberately NOT a Notification Center post. `osascript -e 'display notification'`
// runs under Script Editor's identity; if that app has no notification authorization,
// macOS drops the message and osascript still exits 0 — a silent failure with no error
// to chase. Drawing our own window removes Notification Center from the path entirely,
// so no authorization applies and there is no alert-style toggle to configure.
//
// usage: banner <message> [duration-seconds] [slot] [--focus-iterm2 <session-uuid>]
//
// With --focus-iterm2 the banner becomes clickable and a click jumps to the exact
// iTerm2 tab that produced it. Without it the banner stays click-through, exactly as
// before, so the default behaviour is unchanged.

let incoming = Array(CommandLine.arguments.dropFirst())

var positional: [String] = []
var requestedFocusUUID: String?

var argIndex = 0
while argIndex < incoming.count {
    if incoming[argIndex] == "--focus-iterm2", argIndex + 1 < incoming.count {
        requestedFocusUUID = incoming[argIndex + 1]
        argIndex += 2
        continue
    }
    positional.append(incoming[argIndex])
    argIndex += 1
}

let message  = positional.count > 0 ? positional[0] : "Claude Code"
let duration = positional.count > 1 ? (Double(positional[1]) ?? 5.0) : 5.0
// Slot 0 is the top-right corner; each further slot stacks one banner lower, so
// two sessions finishing at once don't draw on top of each other.
let slot     = positional.count > 2 ? (Int(positional[2]) ?? 0) : 0

// SECURITY: the hook validates this too, but a binary that hands an unchecked string
// to osascript is one refactor away from an injection. An iTerm2 session id is hex and
// dashes, so demanding exactly that shape makes a breakout structurally impossible
// rather than merely escaped. Anything else is dropped and the banner stays passive.
func isSessionUUID(_ candidate: String) -> Bool {
    let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    return candidate.range(of: pattern, options: .regularExpression) != nil
}

let focusUUID: String? = requestedFocusUUID.flatMap { isSessionUUID($0) ? $0 : nil }

// Selecting a specific tab needs AppleScript, which means Automation consent the first
// time. Plain app activation does not, so a denied prompt still lands the user in iTerm2
// — right app, wrong tab — instead of the click doing nothing at all.
func activateITermWithoutAutomation() {
    let bundleID = "com.googlecode.iterm2"
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

// The session id is matched against iTerm2's own `id`, not the wNtNpN coordinates in
// ITERM_SESSION_ID: those are frozen when the session is created and go stale as soon
// as tabs are reordered or closed.
func focusITermSession(_ uuid: String) {
    let script = """
    on run argv
      set target to item 1 of argv
      tell application "iTerm2"
        activate
        repeat with w from 1 to (count of windows)
          repeat with t from 1 to (count of tabs of window w)
            repeat with s from 1 to (count of sessions of tab t of window w)
              set sess to session s of tab t of window w
              if (id of sess) as string is target then
                select window w
                select tab t of window w
                select sess
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "notfound"
    end run
    """

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    // The uuid travels as an argv element, never spliced into the script text, so the
    // question of how to escape it never arises.
    task.arguments = ["-e", script, uuid]
    task.standardOutput = Pipe()
    task.standardError = Pipe()

    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 { activateITermWithoutAutomation() }
    } catch {
        activateITermWithoutAutomation()
    }
}

// Borrow the installed Claude app's own icon rather than committing a copy of it. Keeps a
// binary asset out of a compile-from-source repo, avoids shipping someone else's mark, and
// stays right if that icon ever changes. Falls back to a system symbol so the banner is
// always identifiable, even where the desktop app was never installed.
func claudeIcon() -> NSImage? {
    let workspace = NSWorkspace.shared
    let bundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    for bundleID in bundleIDs {
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return workspace.icon(forFile: url.path)
        }
    }
    let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
    return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude")?
        .withSymbolConfiguration(config)
}

// Borderless windows do not receive clicks until something in the responder chain opts
// in, and a HUD must not become key just because it was clicked — hence both overrides.
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover

final class Banner {
    var window: NSPanel!

    func show(_ text: String, duration: Double, slot: Int, focusUUID: String?) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let w: CGFloat = 380, h: CGFloat = 92
        let vf = screen.visibleFrame
        let y = vf.maxY - h - 16 - CGFloat(slot) * (h + 10)
        let rect = NSRect(x: vf.maxX - w - 16, y: y, width: w, height: h)

        // .nonactivatingPanel matters: without it, clicking the banner activates this
        // process first, stealing the focus we are about to hand to iTerm2.
        window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.level = .statusBar          // floats above normal windows
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Only intercept clicks when there is somewhere to go. With no focus target the
        // banner stays click-through, which is the long-standing behaviour.
        window.ignoresMouseEvents = (focusUUID == nil)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        // Icon on the left, text indented past it. Without this the banner announces
        // itself only in words, which is easy to miss in peripheral vision.
        let iconSize: CGFloat = 28
        let textX = 18 + iconSize + 12
        let textW = w - textX - 18

        if let icon = claudeIcon() {
            let iconView = NSImageView(frame: NSRect(x: 18, y: (h - iconSize) / 2,
                                                    width: iconSize, height: iconSize))
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            // Only tints the symbol fallback; a real app icon keeps its own colours.
            iconView.contentTintColor = .secondaryLabelColor
            blur.addSubview(iconView)
        }

        let title = NSTextField(labelWithString:
            focusUUID == nil ? "Claude Code" : "Claude Code  ·  click to focus")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: textX, y: h - 30, width: textW, height: 16)

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.frame = NSRect(x: textX, y: 14, width: textW, height: h - 52)

        blur.addSubview(title)
        blur.addSubview(body)

        if let uuid = focusUUID {
            let catcher = ClickCatcher(frame: NSRect(x: 0, y: 0, width: w, height: h))
            catcher.onClick = {
                focusITermSession(uuid)
                NSApp.terminate(nil)
            }
            blur.addSubview(catcher)   // added last so it sits above the labels
        }

        window.contentView = blur

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            window.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.45
                self.window.animator().alphaValue = 0
            }, completionHandler: { NSApp.terminate(nil) })
        }
    }
}

let banner = Banner()
banner.show(message, duration: duration, slot: slot, focusUUID: focusUUID)
app.run()
