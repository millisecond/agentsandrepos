import AgentsAndReposCore
import Foundation

/// Polls the agentsandrepos release API on launch and then daily, publishing
/// the newer version string when one exists. Silent on any failure (offline,
/// endpoint not deployed yet) — the banner simply doesn't appear.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableVersion: String?

    private var timer: Timer?

    func start() {
        check()
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 60 * 60
        self.timer = timer
    }

    private func check() {
        Task { [weak self] in
            let request = URLRequest(
                url: UpdateCheck.latestReleaseURL(installID: InstallID.current))
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200
            else { return }
            self?.availableVersion = UpdateCheck.availableUpdate(
                fromReleaseJSON: data, current: Version.current)
        }
    }
}
