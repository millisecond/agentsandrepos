import Foundation
import ServiceManagement
import os

/// Launch-at-login via `SMAppService` (RepoBar-style): registering the main
/// app bundle makes it a normal login item, visible and revocable in
/// System Settings → General → Login Items.
@MainActor
enum LaunchAtLogin {
    private static let log = Logger(
        subsystem: "com.millisecond.agentsandrepos", category: "app")

    /// `SMAppService.mainApp` registers the containing .app bundle; a bare
    /// `swift build` binary has none, so the Settings toggle is hidden there.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
