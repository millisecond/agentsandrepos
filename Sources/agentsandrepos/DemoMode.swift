import AgentsAndReposCore
import AppKit
import ApplicationServices
import QuartzCore
import SwiftUI

/// `--demo` launch mode: the UI runs on `DemoTimeline`'s scripted snapshots
/// instead of the engine, a synthetic cursor showcases the row ⋯ menu, and a
/// backdrop window hides whatever is really on screen. Driven end-to-end by
/// scripts/record-demo.sh to record the README video. Everything here is
/// inert unless the flag is passed.
enum DemoMode {
    static let enabled = CommandLine.arguments.contains("--demo")
}

@MainActor
final class DemoDriver {
    /// Set at init so demo-only view code (frame reporters) can reach the
    /// driver without threading it through every view init.
    private(set) static var shared: DemoDriver?

    enum FrameKind {
        case row  // keyed by RankedTile.id ("repo:<path>")
        case ellipsis  // keyed by RepoTileState.id (<path>)
        case search  // the search bar; id ignored
    }

    private let store: SnapshotStore
    private let statusController: StatusItemController
    private let popoverController: DashboardPopoverController

    /// Frozen at launch: every tick's dates are offsets from this, so "ago"
    /// stamps hold still on camera instead of counting up.
    private let startedAt = Date()
    private var tick = 0
    private var timer: Timer?
    private var backdrop: NSWindow?
    private var printedReady = false
    /// Latest laid-out screen frames (AppKit bottom-left coords), reported by
    /// DemoFrameReporter as SwiftUI lays rows out.
    private var rowFrames: [String: NSRect] = [:]
    private var ellipsisFrames: [String: NSRect] = [:]
    private var searchFrame: NSRect?
    private let axTrusted = AXIsProcessTrusted()

    init(
        store: SnapshotStore, statusController: StatusItemController,
        popoverController: DashboardPopoverController
    ) {
        self.store = store
        self.statusController = statusController
        self.popoverController = popoverController
        Self.shared = self
    }

    func start() {
        if !axTrusted {
            let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
            print(
                """
                DEMO_NEEDS_AX — the ⋯-menu cursor choreography posts synthetic \
                mouse/key events, which needs Accessibility trust for this binary:
                  System Settings → Privacy & Security → Accessibility → add
                  \(binary)
                (Re-tick the checkbox after rebuilds; the grant is per-binary.)
                """)
            fflush(stdout)
        }
        showBackdrop()
        // The status item needs a runloop turn or two to land in the menubar
        // before the popover can anchor to it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.begin()
        }
    }

    private func begin() {
        push()
        if let button = statusController.button {
            popoverController.toggle(relativeTo: button)
        }
        Task { @MainActor [weak self] in
            // One layout pass so the popover window frame is real.
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.printReady()
            self?.startTicking()
        }
    }

    // MARK: - Tick loop

    private func startTicking() {
        // .common mode so ticks keep flowing while the ⋯ NSMenu tracks —
        // otherwise the LEDs (and the Esc that closes the menu) freeze.
        let t = Timer(timeInterval: DemoTimeline.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { DemoDriver.shared?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func advance() {
        tick = (tick + 1) % DemoTimeline.totalTicks
        push()
        // Re-run each loop so re-takes don't need a relaunch.
        if tick == DemoTimeline.searchSceneStart, axTrusted {
            Task { @MainActor [weak self] in await self?.runSearchChoreography() }
        }
        if tick == DemoTimeline.menuSceneStart, axTrusted {
            Task { @MainActor [weak self] in await self?.runChoreography() }
        }
    }

    private func push() {
        let snap = DemoTimeline.snapshot(tick: tick, now: startedAt)
        store.update(snap)
        statusController.update(snapshot: snap)
    }

    // MARK: - Ready signal for record-demo.sh

    /// Prints the capture region (CG top-left coords, as `screencapture -R`
    /// wants): the menubar strip above the status item plus the popover,
    /// padded for the popover's shadow.
    private func printReady() {
        guard !printedReady, let screen = NSScreen.screens.first else { return }
        printedReady = true
        let button = statusController.button?.window?.frame ?? .zero
        let popover = popoverController.popoverWindowFrame ?? button
        var region = button.union(popover).insetBy(dx: -28, dy: 0)
        region.origin.y -= 28
        region.size.height = screen.frame.maxY - region.origin.y
        region = region.intersection(screen.frame)
        let x = Int(region.origin.x)
        let y = Int(screen.frame.maxY - region.maxY)
        print("DEMO_READY region=\(x),\(y),\(Int(region.width)),\(Int(region.height))")
        fflush(stdout)
    }

    // MARK: - Backdrop

    /// Full-screen window above the desktop and other apps, below the popover:
    /// makes the shot deterministic no matter what's really on screen. The
    /// real menubar still draws above it (nothing can repaint that) — the
    /// capture region crops most of it away.
    private func showBackdrop() {
        guard let screen = NSScreen.screens.first else { return }
        let window = NSWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // .floating: normal app windows can't rise above the backdrop even
        // when another app activates mid-recording (e.g. a permission
        // dialog); the popover rides higher still on the status bar level.
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(origin: .zero, size: screen.frame.size)
        gradient.colors = [
            NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.26, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.15, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        let view = NSView(frame: screen.frame)
        view.layer = gradient
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        backdrop = window
    }

    // MARK: - Frame reporting (from DemoFrameReporter)

    func report(kind: FrameKind, id: String, frame: NSRect) {
        switch kind {
        case .row: rowFrames[id] = frame
        case .ellipsis: ellipsisFrames[id] = frame
        case .search: searchFrame = frame
        }
    }

    // MARK: - Cursor choreography

    /// Opening scene: glide to the search bar, click, type the PR number so
    /// the board filters to that one row, dwell so the viewer reads it, then
    /// Esc — the first Escape clears the query and unfocuses, restoring the
    /// full board for the rest of the story.
    private func runSearchChoreography() async {
        NSApp.activate(ignoringOtherApps: true)
        popoverController.makeKeyIfShown()
        guard let bar = searchFrame else {
            print("DEMO_WARN no search-bar frame; skipping search scene")
            fflush(stdout)
            return
        }
        let target = NSPoint(x: bar.midX, y: bar.midY)
        await glide(to: target, over: 0.5)
        await click(at: target)
        try? await Task.sleep(nanoseconds: 250_000_000)
        for char in DemoTimeline.searchQuery {
            typeCharacter(char)
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        try? await Task.sleep(nanoseconds: 2_800_000_000)
        pressEscape()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let popover = popoverController.popoverWindowFrame {
            await glide(to: NSPoint(x: popover.midX, y: popover.minY - 24), over: 0.6)
        }
    }

    /// Glide to the featured row (hover reveals the ⋯ and destination hint),
    /// click the ⋯ so its action menu opens, dwell so the viewer reads it,
    /// Esc it closed, and park below the popover.
    private func runChoreography() async {
        // If anything stole activation since launch, the popover window is no
        // longer key and the ⋯ click would be swallowed as an activation
        // click (SwiftUI controls don't acceptFirstMouse).
        NSApp.activate(ignoringOtherApps: true)
        popoverController.makeKeyIfShown()
        let rowKey = "repo:" + DemoTimeline.featuredRepoPath
        guard let row = rowFrames[rowKey] else {
            print("DEMO_WARN no frame for \(rowKey); skipping ⋯ scene")
            fflush(stdout)
            return
        }
        await glide(to: NSPoint(x: row.midX, y: row.midY), over: 0.9)

        // The ⋯ only exists once hover lands; wait for it to lay out and
        // report its own frame.
        var ellipsis: NSRect?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let f = ellipsisFrames[DemoTimeline.featuredRepoPath] {
                ellipsis = f
                break
            }
        }
        guard let ellipsis else {
            print("DEMO_WARN ⋯ never appeared; skipping menu open")
            fflush(stdout)
            return
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let target = NSPoint(x: ellipsis.midX, y: ellipsis.midY)
        await glide(to: target, over: 0.5)
        try? await Task.sleep(nanoseconds: 250_000_000)
        await click(at: target)
        try? await Task.sleep(nanoseconds: 3_200_000_000)
        pressEscape()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let popover = popoverController.popoverWindowFrame {
            await glide(to: NSPoint(x: popover.midX, y: popover.minY - 24), over: 0.7)
        }
    }

    /// Smoothstep-eased mouse-move interpolation at ~60 events/sec.
    private func glide(to appKitTarget: NSPoint, over duration: TimeInterval) async {
        let start = CGEvent(source: nil)?.location ?? .zero
        let end = cgPoint(appKitTarget)
        let steps = max(1, Int(duration * 60))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t * t * (3 - 2 * t)
            let p = CGPoint(
                x: start.x + (end.x - start.x) * e,
                y: start.y + (end.y - start.y) * e)
            postMouse(.mouseMoved, at: p)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func click(at appKitPoint: NSPoint) async {
        let p = cgPoint(appKitPoint)
        postMouse(.leftMouseDown, at: p)
        try? await Task.sleep(nanoseconds: 90_000_000)
        postMouse(.leftMouseUp, at: p)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
            mouseButton: .left)
        // Button tracking ignores "clicks" with a zero click count.
        if type == .leftMouseDown || type == .leftMouseUp {
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event?.post(tap: .cghidEventTap)
    }

    /// Types one character into the focused field. The unicode string carries
    /// the character, so the virtual keycode (layout-dependent) can be 0.
    private func typeCharacter(_ char: Character) {
        let chars = Array(String(char).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func pressEscape() {
        let escape: CGKeyCode = 53
        CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    /// AppKit screen coords (origin bottom-left of the primary display) →
    /// CGEvent coords (origin top-left of the primary display).
    private func cgPoint(_ p: NSPoint) -> CGPoint {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: primaryMaxY - p.y)
    }
}

// MARK: - Frame reporting views

/// Attached (as a .background) to the views the choreography needs to find.
/// Renders nothing; outside demo mode it is an empty view with zero cost.
struct DemoFrameReporter: View {
    let kind: DemoDriver.FrameKind
    let id: String

    var body: some View {
        if DemoMode.enabled {
            DemoFrameReporterRepresentable(kind: kind, id: id)
        }
    }
}

private struct DemoFrameReporterRepresentable: NSViewRepresentable {
    let kind: DemoDriver.FrameKind
    let id: String

    func makeNSView(context: Context) -> DemoFrameReportingView {
        let view = DemoFrameReportingView()
        view.onFrame = { DemoDriver.shared?.report(kind: kind, id: id, frame: $0) }
        return view
    }

    func updateNSView(_ view: DemoFrameReportingView, context: Context) {
        // Rebind on reuse — LazyVStack recycles rows across ids.
        view.onFrame = { DemoDriver.shared?.report(kind: kind, id: id, frame: $0) }
        view.reportNow()
    }
}

final class DemoFrameReportingView: NSView {
    var onFrame: ((NSRect) -> Void)?

    override func layout() {
        super.layout()
        reportNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportNow()
    }

    func reportNow() {
        guard let window else { return }
        onFrame?(window.convertToScreen(convert(bounds, to: nil)))
    }
}
