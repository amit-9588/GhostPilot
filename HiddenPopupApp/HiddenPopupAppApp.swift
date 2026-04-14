import SwiftUI
import AppKit

// ─────────────────────────────────────────
// MARK: - App Entry Point
// ─────────────────────────────────────────
@main
struct HiddenPopupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We don't need a main window, only menu bar
        Settings { EmptyView() }
    }
}

// ─────────────────────────────────────────
// MARK: - App Delegate (Menu Bar Logic)
// ─────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?
    var popupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — menu bar only app
        NSApp.setActivationPolicy(.accessory)

        // Create Menu Bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "eye.slash.fill",
                                   accessibilityDescription: "Hidden Popup")
            button.action = #selector(togglePopup)
            button.target   = self
        }
    }

    // ── Toggle popup open / close ──
    @objc func togglePopup() {
        if let win = popupWindow, win.isVisible {
            win.orderOut(nil)
            return
        }
        showPopup()
    }

    // ── Build & show the hidden popup ──
    func showPopup() {
        let hostingView = NSHostingView(rootView: PopupView(onClose: { [weak self] in
            self?.popupWindow?.orderOut(nil)
        }))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )

        // ╔══════════════════════════════════╗
        // ║  KEY LINE — Hides from screen    ║
        // ║  recording / screen sharing      ║
        // ╚══════════════════════════════════╝
        window.sharingType = .none   // CGWindowSharingNone under the hood

        window.contentView      = hostingView
        window.isOpaque         = false
        window.backgroundColor  = .clear
        window.level            = .floating         // stays on top
        window.hasShadow        = true

        // Position it just below the menu bar button
        if let screen = NSScreen.main,
           let button = statusItem?.button,
           let buttonWindow = button.window {

            let btnFrame    = button.convert(button.bounds, to: nil)
            let screenFrame = screen.frame
            let winWidth    = CGFloat(320)
            let x           = buttonWindow.frame.minX + btnFrame.minX
            let y           = screenFrame.maxY - 28 - 220   // 28 = menu bar height

            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popupWindow = window
    }
}

// ─────────────────────────────────────────
// MARK: - Popup UI (SwiftUI View)
// ─────────────────────────────────────────
struct PopupView: View {
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {

            // ── Card background ──
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)

            // ── Content ──
            VStack(spacing: 14) {

                Image(systemName: "eye.slash.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.purple)

                Text("Hidden from Screen Share")
                    .font(.headline)

                Text("Only YOU can see this popup.\nViewers on Zoom / Meet see nothing here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Label("Invisible to screen recording", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(8)
            }
            .padding(24)

            // ── Close button ──
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 320, height: 220)
    }
}
