import AgentsAndReposCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let summaries: SummaryService
    private let onSave: (AppConfig) -> Void
    private let onTestNotification: () -> Void

    init(
        summaries: SummaryService, onTestNotification: @escaping () -> Void = {},
        onSave: @escaping (AppConfig) -> Void
    ) {
        self.summaries = summaries
        self.onTestNotification = onTestNotification
        self.onSave = onSave
    }

    func show(config: AppConfig) {
        let hosting = NSHostingController(
            rootView: SettingsView(
                config: config, summaries: summaries,
                onTestNotification: onTestNotification, onSave: onSave))
        if let window {
            window.contentViewController = hosting
        } else {
            let w = NSWindow(contentViewController: hosting)
            w.title = "\(AppInfo.displayName) Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
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
