import AgentsAndReposCore
import Foundation

/// Feeds every published snapshot to the planner and posts whatever it emits.
/// Sits on the same snapshot callback as SnapshotStore, so no extra timers or
/// polling: the 3s agent tick is what detects a waiting threshold crossing.
@MainActor
final class NotificationCoordinator {
    private var planner = NotificationPlanner()
    private let deliverer: NotificationDelivering
    private var wasEnabled = false
    /// Bumped per post of an id; a scheduled expiry only withdraws if its
    /// generation still matches, so a re-posted alert (agent waited again)
    /// isn't taken down by the previous cycle's timer.
    private var postGeneration: [String: Int] = [:]

    init(deliverer: NotificationDelivering? = nil) {
        self.deliverer = deliverer ?? NotificationDeliverers.make()
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
