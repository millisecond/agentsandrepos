import AgentsAndReposCore
import AppKit
import SwiftUI

/// Presents the first-run welcome as a popover anchored to the status item —
/// same chrome as the dashboard, and it shows new users where the app lives.
///
/// Dismissal is hand-rolled rather than `.transient`: a click anywhere
/// outside the popover hides it (event monitors, below), except while the
/// modal folder picker is up — a transient popover would die on the first
/// click into that panel, mid-setup. Hiding saves nothing and keeps the
/// view's state; the owner keeps toggling this controller from the status
/// item until Start or Skip, which are the only ways to finish.
@MainActor
final class OnboardingPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// True while a folder panel is up; clicks in it must not dismiss.
    private var panelShowing = false
    /// Status button the popover is anchored to. Its mouse-down is left to
    /// the button's own action (toggle), not treated as a click-off.
    private weak var anchorButton: NSStatusBarButton?

    init(
        config: AppConfig, onFinish: @escaping (AppConfig) -> Void,
        onSkip: @escaping () -> Void
    ) {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: OnboardingView(
                baseConfig: config,
                // Close before the callback: the owner drops its reference
                // (the only strong one) inside it.
                onFinish: { [weak self] config in
                    self?.close()
                    onFinish(config)
                },
                onSkip: { [weak self] in
                    self?.close()
                    onSkip()
                },
                setPanelShowing: { [weak self] showing in
                    self?.panelShowing = showing
                    // Hide (don't close) while a modal folder panel is up —
                    // popover windows would float above it. Alpha keeps the
                    // popover's state and anchor alive.
                    guard let window = self?.popover.contentViewController?.view.window
                    else { return }
                    window.alphaValue = showing ? 0 : 1
                    if !showing { window.makeKey() }
                }))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    /// At launch the status item's window starts zero-height, then sits
    /// parked at the screen's bottom-left before the menu bar places it;
    /// showing against it too early fails silently or anchors the popover at
    /// the bottom of the screen. Retry until the item is actually up in the
    /// menu bar (top half of its screen).
    func show(relativeTo button: NSStatusBarButton, attemptsLeft: Int = 20) {
        anchorButton = button
        guard let window = button.window, window.frame.height > 0,
            let screen = window.screen ?? NSScreen.main,
            window.frame.minY > screen.frame.midY
        else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.show(relativeTo: button, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installMonitors()
    }

    /// Icon click: hide if showing, otherwise show again with state intact.
    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    /// Global monitor: clicks in other apps (or the desktop). Local monitor:
    /// clicks in our own windows other than the popover and the status item
    /// (whose button action toggles on mouse-up; hiding on its mouse-down
    /// would make that toggle reopen). Neither fires while the folder panel
    /// is up.
    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in self?.dismissUnlessPanel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            let window = event.window
            Task { @MainActor in
                guard let self, let popoverWindow = self.popover.contentViewController?.view.window,
                    window !== popoverWindow, window !== self.anchorButton?.window
                else { return }
                self.dismissUnlessPanel()
            }
            return event
        }
    }

    private func dismissUnlessPanel() {
        guard !panelShowing else { return }
        close()
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func close() {
        popover.performClose(nil)
        removeMonitors()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.removeMonitors() }
    }
}
