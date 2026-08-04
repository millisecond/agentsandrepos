import AgentsAndReposCore
import Foundation
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

extension Duration {
    fileprivate var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// Running timings for on-device generations, for the Settings pane and logs.
struct SummaryGenStats: Equatable {
    var count = 0
    var totalMs: Double = 0
    var lastMs: Double = 0
    var maxMs: Double = 0

    var avgMs: Double { count > 0 ? totalMs / Double(count) : 0 }

    mutating func record(ms: Double) {
        count += 1
        totalMs += ms
        lastMs = ms
        maxMs = max(maxMs, ms)
    }
}

/// Whether on-device summaries can be generated right now. Requires the app to
/// be built against the macOS 26 SDK, running on macOS 26+, with the Apple
/// Intelligence model usable.
enum SummaryAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    static var current: SummaryAvailability {
        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else {
                return .unavailable("requires macOS 26 or later")
            }
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("this Mac doesn't support Apple Intelligence")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("turn on Apple Intelligence in System Settings")
            case .unavailable(.modelNotReady):
                return .unavailable("Apple Intelligence model isn't ready yet")
            case .unavailable:
                return .unavailable("Apple Intelligence model unavailable")
            }
        #else
            return .unavailable("requires macOS 26 and a build with the macOS 26 SDK")
        #endif
    }
}

/// What a tile's summary slot should render: the freshest known text (the
/// previous summary keeps showing while a replacement generates) plus whether
/// a refresh is in progress (spinner).
struct SummaryDisplay: Equatable {
    var text: String?
    var isRefreshing = false

    /// Nothing to render at all — no text and nothing on the way.
    var isEmpty: Bool { text == nil && !isRefreshing }
}

/// Generates and caches one-line LLM summaries for workspace/repo/agent tiles.
/// Facts strings (from `SummaryFacts`) are the cache keys, so a summary is only
/// regenerated when the underlying state actually changed.
///
/// Battery model (this is a glance-at app, not a constant view): repo summaries
/// may regenerate in the background — repo state changes infrequently and
/// caches well — but agent and workspace summaries only regenerate while the
/// popover is visible, because agent statuses flip constantly and would keep
/// the model spinning. Stale popover-only tiles show raw facts on open until
/// their fresh summary lands. Generation runs one request at a time and
/// publishes incrementally.
@MainActor
final class SummaryService: ObservableObject {
    @Published private(set) var summaries: [String: String] = [:]
    /// Timings across all generations this run; nil until the first one lands.
    @Published private(set) var stats: SummaryGenStats?

    private static let log = Logger(
        subsystem: "com.millisecond.agentsandrepos", category: "summaries")

    /// Facts that produced the current `summaries` entry (or a failed attempt,
    /// so a persistently failing prompt isn't retried every tick).
    private var generatedFacts: [String: String] = [:]
    /// When each key last hit the model. Agent statuses flip every few seconds,
    /// which would otherwise keep the model generating continuously.
    private var lastGenAt: [String: Date] = [:]
    private let regenCooldown: TimeInterval = 20
    /// Background (closed-popover) regen backs off harder: active coding bumps
    /// a repo's dirty count on every status tick, and nobody is looking.
    private let backgroundRegenCooldown: TimeInterval = 120

    /// Repo summaries are cheap to keep warm in the background; agent and
    /// workspace facts churn with every status flip, so they wait for the popover.
    private static func isBackgroundKey(_ key: String) -> Bool {
        key.hasPrefix("repo:")
    }
    private var queue: [(key: String, facts: String)] = []
    private var isGenerating = false
    /// The request currently at the model. Kept out of `generatedFacts` until
    /// it completes so the tile keeps its spinner for the whole inference —
    /// marking early made it vanish seconds before the text arrived. Tracked
    /// separately so update() can't re-enqueue it mid-flight.
    private var inFlight: (key: String, facts: String)?
    /// Summary plans from the latest snapshot, in generation-priority order.
    private var wanted: [(key: String, plan: SummaryPlan)] = []
    private var popoverVisible = false

    /// What the tile should render: fixed text immediately; a generated
    /// summary when it matches current facts; while stale, the previous
    /// summary (or the raw facts, truncated) with a refresh spinner; nothing
    /// when there's nothing to say or summaries are off/unavailable.
    func display(for key: String) -> SummaryDisplay {
        guard let plan = wanted.first(where: { $0.key == key })?.plan else {
            return SummaryDisplay(text: summaries[key])
        }
        switch plan {
        case .none:
            return SummaryDisplay()
        case .fixed(let text):
            return SummaryDisplay(text: text)
        case .generate(let facts):
            // generatedFacts matching means fresh — or a failed attempt (nil
            // summary), which must not show a forever-refreshing line.
            if generatedFacts[key] == facts {
                return SummaryDisplay(text: summaries[key] ?? Self.rawFallback(facts))
            }
            return SummaryDisplay(
                text: summaries[key] ?? Self.rawFallback(facts), isRefreshing: true)
        }
    }

    /// With no summary yet (or a failed one), the raw facts stand in — they're
    /// already readable (agent slots are literal messages, workspace facts are
    /// prose). Newlines collapse so the view's line limit does the truncating;
    /// the prefix cap just keeps huge agent messages out of the layout pass.
    private static func rawFallback(_ facts: String) -> String {
        String(facts.prefix(300)).split(whereSeparator: \.isNewline).joined(separator: " · ")
    }

    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        if visible {
            enqueueStale()
            pump()
        }
    }

    func update(snapshot snap: Snapshot) {
        guard snap.config.showLLMSummaries, SummaryAvailability.current.isAvailable else {
            if !summaries.isEmpty { summaries = [:] }
            generatedFacts = [:]
            wanted = []
            queue = []
            return
        }

        // Workspace first (most visible), then agents (most dynamic), then repos.
        var w: [(key: String, plan: SummaryPlan)] = [
            (SummaryFacts.workspaceKey, SummaryFacts.workspacePlan(snap))
        ]
        for t in snap.agentTiles {
            w.append((SummaryFacts.agentUserKey(t), SummaryFacts.agentUserPlan(t)))
            w.append((SummaryFacts.agentAgentKey(t), SummaryFacts.agentAgentPlan(t)))
        }
        for t in snap.repoTiles { w.append((SummaryFacts.repoKey(t), SummaryFacts.repoPlan(t))) }
        for t in snap.worktreeTiles { w.append((SummaryFacts.repoKey(t), SummaryFacts.repoPlan(t))) }
        wanted = w

        let wantedKeys = Set(w.map(\.key))
        for key in summaries.keys where !wantedKeys.contains(key) {
            summaries[key] = nil
            generatedFacts[key] = nil
        }
        // Only keys still planned for generation belong in the queue.
        let generateKeys = Set(w.compactMap { (key, plan) -> String? in
            if case .generate = plan { return key } else { return nil }
        })
        queue.removeAll { !generateKeys.contains($0.key) }
        // A tile that went deterministic sheds its generated leftovers.
        for key in wantedKeys where !generateKeys.contains(key) {
            summaries[key] = nil
            generatedFacts[key] = nil
        }

        enqueueStale()
        pump()
    }

    private func enqueueStale() {
        for (key, plan) in wanted {
            guard case .generate(let facts) = plan, generatedFacts[key] != facts else { continue }
            if inFlight?.key == key, inFlight?.facts == facts { continue }
            if !popoverVisible, !Self.isBackgroundKey(key) { continue }
            let cooldown = popoverVisible ? regenCooldown : backgroundRegenCooldown
            if let i = queue.firstIndex(where: { $0.key == key }) {
                queue[i] = (key, facts)
            } else if let t = lastGenAt[key], Date().timeIntervalSince(t) < cooldown {
                // Stale but recently generated — skip for now; a later snapshot
                // re-queues it once the cooldown passes (facts still differ).
                continue
            } else {
                queue.append((key, facts))
            }
        }
    }

    private func pump() {
        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *), !isGenerating, !queue.isEmpty else { return }
            isGenerating = true
            Task { [weak self] in await self?.drain() }
        #endif
    }

    #if canImport(FoundationModels)
        @available(macOS 26.0, *)
        private func drain() async {
            let clock = ContinuousClock()
            let drainStart = clock.now
            var generated = 0
            // While the popover is closed only repo items are eligible; agent/
            // workspace items wait in the queue for the next open.
            while let i = queue.firstIndex(where: { popoverVisible || Self.isBackgroundKey($0.key) }) {
                let (key, facts) = queue.remove(at: i)
                inFlight = (key, facts)
                lastGenAt[key] = Date()
                let start = clock.now
                let text = await LocalSummarizer.summarize(key: key, facts: facts)
                let ms = (clock.now - start).milliseconds
                generatedFacts[key] = facts
                inFlight = nil
                var s = stats ?? SummaryGenStats()
                s.record(ms: ms)
                stats = s
                if let text {
                    summaries[key] = text
                    Self.log.notice(
                        "generated \(key, privacy: .public) in \(ms, format: .fixed(precision: 0))ms (\(facts.count) chars in, \(text.count) out)")
                } else {
                    Self.log.error(
                        "generation failed for \(key, privacy: .public) after \(ms, format: .fixed(precision: 0))ms")
                }
                generated += 1
            }
            let totalMs = (clock.now - drainStart).milliseconds
            Self.log.notice(
                "drained \(generated) summaries in \(totalMs, format: .fixed(precision: 0))ms")
            isGenerating = false
        }
    #endif
}

#if canImport(FoundationModels)
    /// Thin wrapper over the Apple Intelligence on-device model. One focused
    /// instruction per tile kind — a combined instruction sheet made the small
    /// model paste examples from the wrong kind onto tiles.
    @available(macOS 26.0, *)
    enum LocalSummarizer {
        private static let userMessageInstructions = """
            Summarize what a developer just asked their coding agent to do, in \
            at most 8 words — an imperative fragment like "Split agent summaries \
            into two lines". Respond with the fragment only — no "User asked", \
            no quotation marks, no trailing period, no markdown.
            """

        private static let agentMessageInstructions = """
            Summarize what a coding agent just reported, in at most 8 words — \
            what it did, found, or is asking, like "Rebuilt app; all tests \
            pass". Respond with the fragment only — no "The agent", no \
            quotation marks, no trailing period, no markdown.
            """

        // Validated against the real model (2026-08-01): the one-shot example
        // is what stops it from just gluing the file names together.
        private static let repoInstructions = """
            You title the uncommitted work in a git repository for a dashboard \
            tile. The input lists changed file names and sometimes "Agent task:" \
            lines. Work out what feature or fix the changes are about and answer \
            with a 2-6 word title. Example input: "Changed files: \
            LoginView.swift, AuthService.swift, PasswordReset.swift" has answer: \
            Login and password auth work. Never list or echo the file names \
            themselves; no quotation marks, no trailing period, no markdown.
            """

        private static let workspaceInstructions = """
            Compress developer-workspace stats into one phrase of at most 8 \
            words in the shape "2 agents coding; 3 repos need commits." Respond \
            with the phrase only — no names, no quotation marks, no markdown.
            """

        private static func instructions(forKey key: String) -> String {
            if key.hasPrefix("agent:") {
                return key.hasSuffix(":user") ? userMessageInstructions : agentMessageInstructions
            }
            if key.hasPrefix("repo:") { return repoInstructions }
            return workspaceInstructions
        }

        static func summarize(key: String, facts: String) async -> String? {
            // Fresh session per request: keeps the transcript from growing and
            // avoids concurrent-respond errors on a shared session.
            let session = LanguageModelSession(instructions: instructions(forKey: key))
            let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: 60)
            guard let response = try? await session.respond(to: facts, options: options) else {
                return nil
            }
            return polish(response.content)
        }

        /// Instructions are soft on a 3B model — deterministically strip the
        /// slop it keeps producing anyway: wrapping quotes, boilerplate
        /// prefixes, trailing periods, extra lines.
        static func polish(_ raw: String) -> String? {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? ""
            for prefix in ["Task:", "Working on:", "Working on"] {
                if t.lowercased().hasPrefix(prefix.lowercased()) {
                    t = String(t.dropFirst(prefix.count))
                }
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            while t.hasSuffix(".") { t = String(t.dropLast()) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
#endif
