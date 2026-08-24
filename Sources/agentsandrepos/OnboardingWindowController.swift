import AgentsAndReposCore
import AppKit
import SwiftUI

/// Shows the first-run welcome window. Closing it without finishing keeps the
/// default config (~/Projects), so there is no forced modality.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let onFinish: (AppConfig) -> Void

    init(onFinish: @escaping (AppConfig) -> Void) {
        self.onFinish = onFinish
    }

    func show(config: AppConfig) {
        let hosting = NSHostingController(
            rootView: OnboardingView(baseConfig: config, onFinish: onFinish))
        if let window {
            window.contentViewController = hosting
        } else {
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to \(AppInfo.displayName)"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
