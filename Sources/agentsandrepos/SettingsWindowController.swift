import AgentsAndReposCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let summaries: SummaryService
    private let onSave: (AppConfig) -> Void

    init(summaries: SummaryService, onSave: @escaping (AppConfig) -> Void) {
        self.summaries = summaries
        self.onSave = onSave
    }

    func show(config: AppConfig) {
        let hosting = NSHostingController(
            rootView: SettingsView(config: config, summaries: summaries, onSave: onSave))
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
