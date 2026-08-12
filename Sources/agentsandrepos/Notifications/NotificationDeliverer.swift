import AgentsAndReposCore
import Foundation
import UserNotifications
import os

/// Posts a planned notification to macOS. Two implementations because
/// UNUserNotificationCenter traps ("bundleProxyForCurrentProcess is nil")
/// unless the process runs from a real .app bundle — true for the brew cask,
/// false for the bare `swift build` binary used in development.
@MainActor
protocol NotificationDelivering: AnyObject {
    func requestAuthorization()
    func deliver(_ note: PlannedNotification)
}

let notifyLog = Logger(
    subsystem: "com.millisecond.agentsandrepos", category: "notify")

@MainActor
enum NotificationDeliverers {
    static func make() -> NotificationDelivering {
        // Info.plist is linker-embedded (__info_plist), so bundleIdentifier is
        // non-nil even for the bare binary — only a real .app on disk can
        // register with the notification system, so check the path instead.
        if Bundle.main.bundlePath.hasSuffix(".app") {
            notifyLog.info("delivering via UNUserNotificationCenter")
            return UserNotificationDeliverer()
        }
        notifyLog.info("not an .app bundle — delivering via osascript fallback")
        return OsascriptNotificationDeliverer()
    }
}

/// The real thing: Notification Center via UserNotifications, with the
/// system permission prompt on first enable.
@MainActor
final class UserNotificationDeliverer: NotificationDelivering {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, error in
            notifyLog.info(
                "authorization granted=\(granted) error=\(String(describing: error))")
        }
    }

    func deliver(_ note: PlannedNotification) {
        notifyLog.info("deliver (UN): \(note.id, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = note.kind == .actionPassed ? nil : .default
        let request = UNNotificationRequest(
            identifier: note.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifyLog.error(
                    "UN add failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// Dev fallback for unbundled binaries: `osascript -e 'display notification'`.
/// Attributes to Script Editor and needs no authorization. One spawn per
/// notification actually fired — rare, so within the subprocess budget.
@MainActor
final class OsascriptNotificationDeliverer: NotificationDelivering {
    func requestAuthorization() {}

    func deliver(_ note: PlannedNotification) {
        notifyLog.info("deliver (osascript): \(note.id, privacy: .public)")
        var script =
            "display notification \(quoted(note.body)) with title \(quoted(note.title))"
        if note.kind != .actionPassed { script += " sound name \"Glass\"" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let stderr = Pipe()
        proc.standardError = stderr
        proc.terminationHandler = { p in
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            if p.terminationStatus != 0 {
                notifyLog.error(
                    "osascript exit \(p.terminationStatus): \(err ?? "", privacy: .public)")
            } else {
                notifyLog.info("osascript delivered ok")
            }
        }
        do { try proc.run() } catch {
            notifyLog.error("osascript spawn failed: \(String(describing: error))")
        }
    }

    private func quoted(_ s: String) -> String {
        "\""
            + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
