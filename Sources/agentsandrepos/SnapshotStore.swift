import AgentsAndReposCore
import Combine
import Foundation

/// Observable bridge between the RefreshEngine's snapshot callback and SwiftUI.
///
/// Updates only flow to SwiftUI while the popover is visible: the popover's
/// hosting view (and its window, once shown) stays alive after close, so an
/// unguarded @Published write re-renders the whole dashboard on every poll
/// tick even when nothing is on screen.
@MainActor
final class SnapshotStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot = .empty
    private var pending: Snapshot?
    private var live = false

    func update(_ snap: Snapshot) {
        if live { publishIfChanged(snap) } else { pending = snap }
    }

    /// Popover visibility. Going live flushes the snapshot that arrived while
    /// hidden, so the dashboard is current the moment it appears.
    func setLive(_ nowLive: Bool) {
        live = nowLive
        if nowLive, let p = pending {
            pending = nil
            publishIfChanged(p)
        }
    }

    /// Skips no-op publishes so the 3s agent tick doesn't churn SwiftUI
    /// diffing (and tile animations) when nothing actually changed.
    private func publishIfChanged(_ snap: Snapshot) {
        if snap != snapshot { snapshot = snap }
    }
}
