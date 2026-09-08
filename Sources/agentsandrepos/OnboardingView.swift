import AgentsAndReposCore
import AppKit
import SwiftUI

/// First-run welcome: choose where repositories live. Defaults to scanning
/// ~/Projects; the user can point at a different projects folder or hand-pick
/// individual repository directories instead. Everything here is editable
/// later in Settings.
struct OnboardingView: View {
    enum Mode: Hashable {
        case scanFolder
        case individual
    }

    @State private var mode: Mode = .scanFolder
    @State private var mainFolder = "~/Projects"
    @State private var individualDirs: [String] = []
    @State private var foundCount: Int?
    let baseConfig: AppConfig
    let onFinish: (AppConfig) -> Void
    let onSkip: () -> Void
    /// Popover windows float above modal open panels; the controller uses
    /// this to hide the popover while a folder picker is up.
    let setPanelShowing: (Bool) -> Void

    private var chosenRoots: [String] {
        mode == .scanFolder ? [mainFolder] : individualDirs
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Welcome to \(AppInfo.displayName)")
                    .font(.title2.bold())
                Text("Tell it where your git repositories live. You can change this any time in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            Form {
                Section {
                    Picker("", selection: $mode) {
                        Text("Scan a projects folder").tag(Mode.scanFolder)
                        Text("Pick repositories").tag(Mode.individual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if mode == .scanFolder {
                    Section {
                        HStack {
                            Text(mainFolder)
                            Spacer()
                            Button("Choose…") { chooseMainFolder() }
                        }
                        Text("Every git repository up to \(baseConfig.scanDepth) levels below this folder is tracked; new ones are picked up automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if individualDirs.isEmpty {
                            Text("No repositories added yet")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(individualDirs, id: \.self) { dir in
                            HStack {
                                Text(dir)
                                Spacer()
                                Button(role: .destructive) {
                                    individualDirs.removeAll { $0 == dir }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Repositories…") { addIndividualDirs() }
                    }
                }

                Section {
                    if let n = foundCount {
                        Label(
                            n == 0
                                ? "No git repositories found here yet"
                                : (n == 1 ? "Found 1 git repository" : "Found \(n) git repositories"),
                            systemImage: n == 0 ? "questionmark.folder" : "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .task(id: chosenRoots) {
                let roots = chosenRoots
                let depth = baseConfig.scanDepth
                guard !roots.isEmpty else {
                    foundCount = nil
                    return
                }
                foundCount = await Task.detached {
                    RepoDiscovery.discover(roots: roots, maxDepth: depth).count
                }.value
            }

            HStack {
                Button("Skip") { onSkip() }
                Spacer()
                Button("Start") {
                    var config = baseConfig
                    config.roots = chosenRoots
                    onFinish(config)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosenRoots.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 420)
    }

    private func chooseMainFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: (mainFolder as NSString).expandingTildeInPath)
        setPanelShowing(true)
        defer { setPanelShowing(false) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mainFolder = Snapshot.abbreviatePath(url.path)
    }

    private func addIndividualDirs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        setPanelShowing(true)
        defer { setPanelShowing(false) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = Snapshot.abbreviatePath(url.path)
            if !individualDirs.contains(path) { individualDirs.append(path) }
        }
    }
}
