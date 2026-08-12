import Cocoa

// A borderless, click-through HUD that appears in the top-right corner and fades out.
//
// Deliberately NOT a Notification Center post. `osascript -e 'display notification'`
// runs under Script Editor's identity; if that app has no notification authorization,
// macOS drops the message and osascript still exits 0 — a silent failure with no error
// to chase. Drawing our own window removes Notification Center from the path entirely,
// so no authorization applies and there is no alert-style toggle to configure.
//
// usage: banner <message> [duration-seconds] [slot]

let message  = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Claude Code"
let duration = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 5.0) : 5.0
// Slot 0 is the top-right corner; each further slot stacks one banner lower, so
// two sessions finishing at once don't draw on top of each other.
let slot     = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 0) : 0

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover

final class Banner {
    var window: NSWindow!

    func show(_ text: String, duration: Double, slot: Int) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let w: CGFloat = 380, h: CGFloat = 92
        let vf = screen.visibleFrame
        let y = vf.maxY - h - 16 - CGFloat(slot) * (h + 10)
        let rect = NSRect(x: vf.maxX - w - 16, y: y, width: w, height: h)

        window = NSWindow(contentRect: rect, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.level = .statusBar          // floats above normal windows
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true   // never steals a click
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Claude Code")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 18, y: h - 30, width: w - 36, height: 16)

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.frame = NSRect(x: 18, y: 14, width: w - 36, height: h - 52)

        blur.addSubview(title)
        blur.addSubview(body)
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
banner.show(message, duration: duration, slot: slot)
app.run()
