import AgentsAndReposCore
import Foundation
import UserNotifications

/// Posts a planned notification to macOS. Two implementations because
/// UNUserNotificationCenter traps ("bundleProxyForCurrentProcess is nil")
/// unless the process runs from a real .app bundle — true for the brew cask,
/// false for the bare `swift build` binary used in development.
@MainActor
protocol NotificationDelivering: AnyObject {
    func requestAuthorization()
    func deliver(_ note: PlannedNotification)
}

@MainActor
enum NotificationDeliverers {
    static func make() -> NotificationDelivering {
        Bundle.main.bundleIdentifier != nil
            ? UserNotificationDeliverer()
            : OsascriptNotificationDeliverer()
    }
}

/// The real thing: Notification Center via UserNotifications, with the
/// system permission prompt on first enable.
@MainActor
final class UserNotificationDeliverer: NotificationDelivering {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
        }
    }

    func deliver(_ note: PlannedNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = note.kind == .actionPassed ? nil : .default
        let request = UNNotificationRequest(
            identifier: note.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Dev fallback for unbundled binaries: `osascript -e 'display notification'`.
/// Attributes to Script Editor and needs no authorization. One spawn per
/// notification actually fired — rare, so within the subprocess budget.
@MainActor
final class OsascriptNotificationDeliverer: NotificationDelivering {
    func requestAuthorization() {}

    func deliver(_ note: PlannedNotification) {
        let script =
            "display notification \(quoted(note.body)) with title \(quoted(note.title))"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    private func quoted(_ s: String) -> String {
        "\""
            + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
