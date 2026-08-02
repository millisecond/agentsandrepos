import Foundation

/// Pure parsing for `tmux list-panes -a` / `tmux list-clients` output, used
/// to map a Claude agent's tty to the tmux pane hosting it and then to the
/// attached client whose terminal window should be focused. Session names
/// go last in each format string so a name containing the separator can't
/// shift the fixed fields.
public enum TmuxLocator {

    public struct Pane: Equatable, Sendable {
        /// tmux pane id, e.g. "%3" — stable, unlike indexes.
        public let paneId: String
        /// tmux window id, e.g. "@1".
        public let windowId: String
        /// Pane pty device, e.g. "/dev/ttys012".
        public let tty: String
        public let sessionName: String

        public init(paneId: String, windowId: String, tty: String, sessionName: String) {
            self.paneId = paneId
            self.windowId = windowId
            self.tty = tty
            self.sessionName = sessionName
        }
    }

    public struct Client: Equatable, Sendable {
        /// The client's own pty in the hosting terminal, e.g. "/dev/ttys003".
        public let tty: String
        /// Pid of the `tmux` client process (its ancestors reach the GUI app).
        public let pid: pid_t
        public let sessionName: String

        public init(tty: String, pid: pid_t, sessionName: String) {
            self.tty = tty
            self.pid = pid
            self.sessionName = sessionName
        }
    }

    /// Format for `tmux list-panes -a -F`.
    public static let paneFormat = "#{pane_id}\t#{window_id}\t#{pane_tty}\t#{session_name}"
    /// Format for `tmux list-clients -F`.
    public static let clientFormat = "#{client_tty}\t#{client_pid}\t#{client_session}"

    public static func pane(matchingTTY tty: String, inListOutput output: String) -> Pane? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[2] == tty else { continue }
            return Pane(
                paneId: String(fields[0]),
                windowId: String(fields[1]),
                tty: String(fields[2]),
                sessionName: String(fields[3])
            )
        }
        return nil
    }

    public static func clients(fromListOutput output: String) -> [Client] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let pid = pid_t(fields[1]) else { return nil }
            return Client(tty: String(fields[0]), pid: pid, sessionName: String(fields[2]))
        }
    }

    /// A client already viewing the pane's session wins; otherwise any client
    /// (the caller switch-clients it over). Nil when the server is detached.
    public static func bestClient(forSession session: String, in clients: [Client]) -> Client? {
        clients.first { $0.sessionName == session } ?? clients.first
    }
}
