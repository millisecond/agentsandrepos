import Foundation

/// Visibility rule for the one-time "enable notifications?" banner at the top
/// of the dashboard.
public enum NotificationPrompt {
    /// The banner quietly retires this long after it first appeared.
    public static let autoDismissAfter: TimeInterval = 24 * 3600

    /// Show while notifications are off, the user hasn't dismissed it, and it
    /// hasn't aged out. First appearance is stamped by the banner itself
    /// (`RefreshEngine.noteNotificationsPromptShown`), so the day counts from
    /// when the user could actually have seen it, not from install.
    public static func shouldShow(config: AppConfig, now: Date) -> Bool {
        guard !config.notificationsEnabled, !config.notificationsPromptDismissed else {
            return false
        }
        guard let shown = config.notificationsPromptFirstShownAt else { return true }
        return now.timeIntervalSince(shown) < autoDismissAfter
    }
}
