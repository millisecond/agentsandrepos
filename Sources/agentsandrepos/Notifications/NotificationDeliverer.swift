import AgentsAndReposCore
import AppKit
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
    /// Take down delivered notifications: clears the on-screen alert AND the
    /// Notification Center entry (macOS offers no screen-only dismissal).
    func withdraw(_ ids: [String])
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
/// system permission prompt on first enable. Clicks route through
/// `NotificationClickRouter` to the same destinations as the dashboard tiles.
@MainActor
final class UserNotificationDeliverer: NotificationDelivering {
    /// Center delegate must be strongly held for the app's lifetime.
    private let router = NotificationClickRouter()

    init() {
        UNUserNotificationCenter.current().delegate = router
        UNUserNotificationCenter.current().getNotificationSettings { s in
            notifyLog.info(
                "settings: auth=\(s.authorizationStatus.rawValue) alertSetting=\(s.alertSetting.rawValue) style=\(s.alertStyle.rawValue)")
        }
    }

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
        content.userInfo = NotificationClickRouter.userInfo(for: note.target)
        let request = UNNotificationRequest(
            identifier: note.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifyLog.error(
                    "UN add failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        notifyLog.info("withdraw: \(ids.joined(separator: ", "), privacy: .public)")
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Decodes a click target out of the notification's userInfo and sends the
/// user where the matching dashboard tile click would: an agent's terminal
/// window (Finder fallback) or a run's GitHub page.
final class NotificationClickRouter: NSObject, UNUserNotificationCenterDelegate {
    static func userInfo(for target: PlannedNotification.ClickTarget?) -> [AnyHashable: Any] {
        switch target {
        case .url(let url):
            return ["target": "url", "url": url]
        case .agent(let pid, let cwd):
            return ["target": "agent", "pid": Int(pid), "cwd": cwd]
        case nil:
            return [:]
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only the plain click/default action navigates; a swipe-dismiss doesn't.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        let kind = info["target"] as? String
        let url = info["url"] as? String
        let pid = info["pid"] as? Int
        let cwd = info["cwd"] as? String
        Task { @MainActor in
            switch kind {
            case "url":
                if let url, let parsed = URL(string: url) {
                    notifyLog.info("click → \(url, privacy: .public)")
                    NSWorkspace.shared.open(parsed)
                }
            case "agent":
                if let pid, let cwd {
                    notifyLog.info("click → agent pid \(pid)")
                    if !TerminalFocus.focus(agentPid: Int32(pid), cwd: cwd) {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: cwd, isDirectory: true))
                    }
                }
            default:
                break
            }
        }
        completionHandler()
    }

    /// Show banners even while the app is "frontmost" (popover open) —
    /// otherwise macOS suppresses them exactly when the user is looking.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Dev fallback for unbundled binaries: `osascript -e 'display notification'`.
/// Attributes to Script Editor and needs no authorization. One spawn per
/// notification actually fired — rare, so within the subprocess budget.
@MainActor
final class OsascriptNotificationDeliverer: NotificationDelivering {
    func requestAuthorization() {}

    /// Fire-and-forget: osascript notifications can't be taken back.
    func withdraw(_ ids: [String]) {}

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
