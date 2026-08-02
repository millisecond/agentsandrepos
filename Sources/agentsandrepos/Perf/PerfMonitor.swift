import AgentsAndReposCore
import Darwin
import Foundation
import os

/// Watches this process's own CPU use so a performance regression announces
/// itself (dashboard banner + unified log) instead of waiting for someone to
/// open Activity Monitor. One getrusage call every 30s — effectively free.
@MainActor
final class PerfMonitor: ObservableObject {
    /// Non-nil while sustained CPU is above the warn threshold.
    @Published private(set) var warning: String?

    private var model = CPUWatchdogModel()
    private var loop: Task<Void, Never>?
    private static let interval: TimeInterval = 30
    private static let log = Logger(
        subsystem: "com.millisecond.agentsandrepos", category: "perf")

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard let self else { return }
                self.sample()
            }
        }
    }

    private func sample() {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return }
        let cpu =
            Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        let wasHot = model.isHot
        let hot = model.record(cpuSeconds: cpu, at: Date())

        // Rounded to 5% steps so the banner text (and thus the SwiftUI view
        // tree observing it) only changes when the picture meaningfully moves.
        let pct = max(5, Int((model.averageFraction * 20).rounded()) * 5)
        let newWarning = hot ? "High CPU: averaging ~\(pct)% over the last 5 minutes" : nil
        if warning != newWarning { warning = newWarning }

        if hot != wasHot {
            if hot {
                Self.log.error(
                    "sustained high CPU: ~\(pct, privacy: .public)% 5m average")
            } else {
                Self.log.notice("high CPU cleared")
            }
        }
    }
}
