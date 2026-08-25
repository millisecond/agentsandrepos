import AgentsAndReposCore
import AppKit
import SwiftUI

/// Presents the first-run welcome as a popover anchored to the status item —
/// same chrome as the dashboard, and it shows new users where the app lives.
/// `.applicationDefined` behavior so the folder-picker panel (or a stray
/// click) can't dismiss it mid-setup; the view's Skip and Start buttons are
/// the only ways out, and skipping keeps the default config (~/Projects).
@MainActor
final class OnboardingPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()

    init(config: AppConfig, onFinish: @escaping (AppConfig) -> Void) {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: OnboardingView(
                baseConfig: config,
                onFinish: onFinish,
                onSkip: { [weak self] in self?.close() },
                setPanelShowing: { [weak self] showing in
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
    }

    /// Fires on any close (Skip, Start, dashboard opening) so the owner can
    /// drop its reference.
    var onClose: (() -> Void)?

    func close() {
        popover.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.onClose?() }
    }
}
