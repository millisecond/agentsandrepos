import Foundation

/// Parses `wezterm cli list --format json` to find the pane whose pty matches
/// a Claude agent's tty. `wezterm cli activate-pane` then focuses pane, tab,
/// and window in one step.
public enum WezTermPanes {

    public struct Pane: Equatable, Sendable {
        public let paneId: Int
        public let tabId: Int
        public let windowId: Int
        /// Pane pty device, e.g. "/dev/ttys012".
        public let tty: String

        public init(paneId: Int, tabId: Int, windowId: Int, tty: String) {
            self.paneId = paneId
            self.tabId = tabId
            self.windowId = windowId
            self.tty = tty
        }
    }

    private struct Entry: Decodable {
        let paneId: Int
        let tabId: Int
        let windowId: Int
        let ttyName: String?

        enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case tabId = "tab_id"
            case windowId = "window_id"
            case ttyName = "tty_name"
        }
    }

    public static func pane(matchingTTY tty: String, inListJSON data: Data) -> Pane? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return entries.first { $0.ttyName == tty }.map {
            Pane(paneId: $0.paneId, tabId: $0.tabId, windowId: $0.windowId, tty: tty)
        }
    }
}
