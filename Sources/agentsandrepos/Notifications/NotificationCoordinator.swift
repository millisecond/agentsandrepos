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
        for note in planner.ingest(snapshot, now: Date()) {
            deliverer.deliver(note)
        }
    }
}
