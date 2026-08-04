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
    /// Mirrors popover visibility for views: continuous animations (spinning
    /// gears, summary spinners) must render their static variant while this
    /// is false, or the closed popover's still-alive window keeps servicing
    /// them at display refresh forever (~30% CPU, and gated snapshots mean a
    /// stale busy gear never clears). The write on close is the one deliberate
    /// offscreen re-render that tears the animations down.
    @Published private(set) var isLive = false
    private var pending: Snapshot?

    func update(_ snap: Snapshot) {
        if isLive { publishIfChanged(snap) } else { pending = snap }
    }

    /// Popover visibility. Going live flushes the snapshot that arrived while
    /// hidden, so the dashboard is current the moment it appears.
    func setLive(_ nowLive: Bool) {
        if isLive != nowLive { isLive = nowLive }
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
