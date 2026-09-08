import AgentsAndReposCore
import Foundation

/// Feeds every published snapshot to the planner and posts whatever it emits.
/// Sits on the same snapshot callback as SnapshotStore, so no extra timers or
/// polling: the 3s agent tick is what detects a waiting threshold crossing.
@MainActor
final class NotificationCoordinator {
    private var planner: NotificationPlanner
    private let deliverer: NotificationDelivering
    private let beliefsURL: URL
    private var wasEnabled = false
    /// Bumped per post of an id; a scheduled expiry only withdraws if its
    /// generation still matches, so a re-posted alert (agent waited again)
    /// isn't taken down by the previous cycle's timer.
    private var postGeneration: [String: Int] = [:]

    init(deliverer: NotificationDelivering? = nil, beliefsURL: URL = BeliefStore.url) {
        self.deliverer = deliverer ?? NotificationDeliverers.make()
        self.beliefsURL = beliefsURL
        // Beliefs persist so a workflow seen last week is still "known" and
        // its routine results stay quiet from the first run after launch.
        let beliefs = BeliefStore.load(from: beliefsURL)
        self.planner = NotificationPlanner(beliefs: beliefs)
        notifyLog.info("loaded \(beliefs.count) run beliefs")
    }

    func requestAuthorization() {
        deliverer.requestAuthorization()
    }

    /// Settings' "Send Test Notification": exercises the deliverer directly,
    /// bypassing the planner and the enabled gate, so delivery/permission
    /// problems can be diagnosed independently of real triggers.
    func sendTest() {
        deliverer.deliver(
            PlannedNotification(
                id: "test-\(UUID().uuidString)",
                kind: .agentWaiting,
                title: "Test notification",
                body: "Delivery from Agents & Repos is working."))
    }

    func ingest(_ snapshot: Snapshot) {
        guard snapshot.config.notificationsEnabled else {
            // Drop state so re-enabling re-primes instead of replaying every
            // transition that happened while off.
            if wasEnabled {
                planner.reset()
                wasEnabled = false
            }
            return
        }
        wasEnabled = true
        let plan = planner.ingest(snapshot, now: Date())
        // One line per scored run — the raw material for calibrating the
        // tier cutoffs from real data later (`log show --predicate
        // 'category == "notify"'`).
        for scored in plan.scored {
            let parts = scored.surprise.components
                .map { "\($0.name)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")
            notifyLog.info(
                "surprise \(scored.key, privacy: .public) score=\(String(format: "%.2f", scored.surprise.score), privacy: .public) tier=\(scored.surprise.tier.rawValue, privacy: .public) \(parts, privacy: .public)")
        }
        if let beliefs = planner.takeDirtyBeliefs() {
            BeliefStore.save(beliefs, to: beliefsURL)
        }
        deliverer.withdraw(plan.withdraw)
        for id in plan.withdraw { postGeneration[id] = nil }
        for note in plan.post {
            deliverer.deliver(note)
            scheduleExpiry(of: note)
        }
    }

    /// Alerts persist until acted on (NSUserNotificationAlertStyle); the
    /// expiry takes an ignored one down after its window.
    private func scheduleExpiry(of note: PlannedNotification) {
        guard let ttl = note.expiresAfter else { return }
        let generation = (postGeneration[note.id] ?? 0) + 1
        postGeneration[note.id] = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ttl))
            guard let self, self.postGeneration[note.id] == generation else { return }
            self.postGeneration[note.id] = nil
            self.deliverer.withdraw([note.id])
        }
    }
}
