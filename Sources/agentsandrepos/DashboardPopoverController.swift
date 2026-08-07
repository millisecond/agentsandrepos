import AgentsAndReposCore
import AppKit
import SwiftUI

/// Show-time state pushed from the popover controller: screen-derived layout
/// limits, refreshed each time the popover is shown so the dashboard can grow
/// to the height of whatever screen it opens on, plus a scroll-reset signal.
@MainActor
final class DashboardSizing: ObservableObject {
    @Published var maxContentHeight: CGFloat = 700
    /// Bumped when the popover reopens after sitting closed for a while, so
    /// the dashboard resets to the top instead of restoring a stale offset.
    @Published var scrollToTopTick = 0
}

/// Owns the NSPopover that hosts the SwiftUI dashboard.
@MainActor
final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let sizing = DashboardSizing()
    private var globalMonitor: Any?
    /// Transient popovers close themselves on the mouse-down of a status-bar
    /// click; without this guard the following mouse-up action would
    /// immediately reopen them.
    private var lastCloseAt: Date = .distantPast
    /// Reopening after this long closed resets the dashboard scroll to top;
    /// quick close/reopen cycles keep the user's place.
    private static let scrollResetAfter: TimeInterval = 30

    var isShown: Bool { popover.isShown }

    /// Fires with true on show and false on close — the engine uses this to
    /// front-run GitHub refreshes and follow in-flight workflow runs.
    var onVisibilityChange: ((Bool) -> Void)?

    private let summaries: SummaryService
    private let store: SnapshotStore
    private let perf: PerfMonitor

    init(
        store: SnapshotStore, actions: DashboardActions, summaries: SummaryService,
        updates: UpdateChecker, perf: PerfMonitor
    ) {
        self.summaries = summaries
        self.store = store
        self.perf = perf
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: DashboardView(
                store: store, actions: actions, sizing: sizing, summaries: summaries,
                updates: updates, perf: perf))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else if Date().timeIntervalSince(lastCloseAt) > 0.25 {
            show(relativeTo: button)
        }
    }

    private func show(relativeTo button: NSStatusBarButton) {
        // visibleFrame already excludes the menu bar and Dock; leave a little
        // slack for the popover arrow and shadow chrome.
        if let screen = button.window?.screen ?? NSScreen.main {
            sizing.maxContentHeight = screen.visibleFrame.height - 24
        }
        let resetScroll = Date().timeIntervalSince(lastCloseAt) > Self.scrollResetAfter
        // Resume snapshot flow before showing so the dashboard lays out with
        // current data instead of rendering stale content then re-rendering.
        store.setLive(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bump after show so the (reused) hosting view is in a window and
        // observes the change.
        if resetScroll { sizing.scrollToTopTick += 1 }
        popover.contentViewController?.view.window?.makeKey()
        // LLM summaries only generate while the popover is visible (battery).
        summaries.setPopoverVisible(true)
        onVisibilityChange?(true)
        // Foreground CPU (rendering, summaries) doesn't count against the
        // background-CPU watchdog.
        perf.setPopoverVisible(true)
        // Transient popovers in .accessory apps don't reliably dismiss when the
        // click lands in another app. Global monitors never see our own app's
        // events, so this can't interfere with in-popover clicks/context menus.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        popover.performClose(nil)
        removeMonitor()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.lastCloseAt = Date()
            self.removeMonitor()
            self.summaries.setPopoverVisible(false)
            self.perf.setPopoverVisible(false)
            self.store.setLive(false)
            self.onVisibilityChange?(false)
        }
    }

    private func removeMonitor() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }
}
