import AgentsAndReposCore
import AppKit

/// Builds the dropdown menu from a Snapshot. Menus are rebuilt on every open
/// (menuNeedsUpdate) and never mutated while visible.
@MainActor
enum MenuBuilder {

    /// Max entries shown inline per section; the rest go into a "More…" submenu
    /// so the top-level menu always stays a scannable overview.
    private static let sectionLimit = 10

    /// Adds item-groups to the menu, hiding overflow beyond `sectionLimit`
    /// groups in a "More…" submenu. A group stays together (e.g. a repo row
    /// plus its worktree rows).
    private static func addCapped(_ groups: [[NSMenuItem]], to menu: NSMenu) {
        for group in groups.prefix(sectionLimit) {
            group.forEach { menu.addItem($0) }
        }
        let overflow = groups.dropFirst(sectionLimit)
        guard !overflow.isEmpty else { return }
        let more = NSMenuItem(title: "More (\(overflow.count))…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for group in overflow {
            group.forEach { sub.addItem($0) }
        }
        more.submenu = sub
        menu.addItem(more)
    }

    static func rebuild(menu: NSMenu, snapshot: Snapshot, controller: StatusItemController) {
        menu.removeAllItems()
        buildAgentsSection(menu, snapshot, controller)
        menu.addItem(.separator())
        buildReposSection(menu, snapshot, controller)
        menu.addItem(.separator())
        buildPRsSection(menu, snapshot, controller)
        menu.addItem(.separator())
        buildFooter(menu, snapshot)
        menu.addItem(.separator())
        buildControls(menu, snapshot, controller)
    }

    // MARK: - Agents

    private static func buildAgentsSection(
        _ menu: NSMenu, _ s: Snapshot, _ c: StatusItemController
    ) {
        menu.addItem(NSMenuItem.sectionHeader(title: "Claude Agents"))
        var groups: [[NSMenuItem]] = []

        func addAgent(_ agent: AgentSession, location: String, path: String) {
            let bg = agent.isBackground ? " (bg)" : ""
            let item = NSMenuItem(
                title: "\(agent.status.glyph) \(agent.displayName)\(bg)",
                action: #selector(StatusItemController.openInFinderAction(_:)),
                keyEquivalent: "")
            item.target = c
            item.representedObject = path
            item.attributedTitle = twoTone(
                primary: "\(agent.status.glyph) \(agent.displayName)\(bg)",
                secondary: "  \(agent.status.label) · \(location)")
            groups.append([item])
        }

        for r in s.repos {
            for a in r.agents where !s.isAgentIgnored(a.sessionId) {
                addAgent(a, location: r.repo.name, path: r.repo.path)
            }
            for wt in r.worktrees {
                for a in wt.agents where !s.isAgentIgnored(a.sessionId) {
                    addAgent(a, location: "\(r.repo.name) ⎇ \(wt.worktree.name)", path: wt.worktree.path)
                }
            }
        }
        for a in s.otherAgents where !s.isAgentIgnored(a.sessionId) {
            addAgent(a, location: abbreviate(a.cwd), path: a.cwd)
        }
        if groups.isEmpty {
            menu.addItem(disabled("No agents running"))
        } else {
            addCapped(groups, to: menu)
        }
    }

    // MARK: - Repos

    private static func buildReposSection(
        _ menu: NSMenu, _ s: Snapshot, _ c: StatusItemController
    ) {
        let visible = s.visibleRepos
        let attention = visible.filter(\.needsAttention)
        menu.addItem(NSMenuItem.sectionHeader(title: "Needs Attention"))
        if attention.isEmpty {
            menu.addItem(disabled(visible.isEmpty ? "No repos found" : "All repos clean"))
        }
        let groups = attention.map { r -> [NSMenuItem] in
            var group = [repoItem(r, c)]
            for wt in r.worktrees where wt.git?.needsAttention == true || !wt.agents.isEmpty {
                group.append(worktreeItem(wt, c))
            }
            return group
        }
        addCapped(groups, to: menu)

        // Full list tucked into a submenu.
        let allItem = NSMenuItem(title: "All Repos (\(visible.count))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for r in visible {
            sub.addItem(repoItem(r, c))
            for wt in r.worktrees {
                sub.addItem(worktreeItem(wt, c))
            }
        }
        allItem.submenu = sub
        menu.addItem(allItem)
    }

    private static func repoItem(_ r: RepoOverview, _ c: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: r.repo.name, action: nil, keyEquivalent: "")
        item.attributedTitle = twoTone(
            primary: r.repo.name, secondary: "  \(r.git?.summary ?? "…")")
        item.submenu = locationSubmenu(
            path: r.repo.path, githubRepo: r.githubRepo, controller: c, includeFetch: true)
        return item
    }

    private static func worktreeItem(_ wt: WorktreeOverview, _ c: StatusItemController) -> NSMenuItem {
        let claude = wt.isClaudeManaged ? " · claude" : ""
        let item = NSMenuItem(title: wt.worktree.name, action: nil, keyEquivalent: "")
        item.attributedTitle = twoTone(
            primary: "   ⎇ \(wt.worktree.name)",
            secondary: "  \(wt.git?.summary ?? wt.worktree.branch ?? "")\(claude)")
        item.submenu = locationSubmenu(
            path: wt.worktree.path, githubRepo: nil, controller: c, includeFetch: false)
        return item
    }

    private static func locationSubmenu(
        path: String, githubRepo: String?, controller c: StatusItemController, includeFetch: Bool
    ) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(actionItem("Open in Finder", #selector(StatusItemController.openInFinderAction(_:)), path, c))
        sub.addItem(actionItem("Open in Terminal", #selector(StatusItemController.openInTerminalAction(_:)), path, c))
        if let githubRepo {
            sub.addItem(actionItem(
                "Open on GitHub", #selector(StatusItemController.openURLAction(_:)),
                "https://github.com/\(githubRepo)", c))
        }
        sub.addItem(actionItem("Copy Path", #selector(StatusItemController.copyPathAction(_:)), path, c))
        if includeFetch {
            sub.addItem(.separator())
            sub.addItem(actionItem("Fetch Now", #selector(StatusItemController.fetchNowAction(_:)), path, c))
        }
        return sub
    }

    // MARK: - PRs

    private static func buildPRsSection(
        _ menu: NSMenu, _ s: Snapshot, _ c: StatusItemController
    ) {
        let scope = s.config.prScope == .mine ? "Mine" : "All"
        menu.addItem(NSMenuItem.sectionHeader(title: "Pull Requests · \(scope)"))
        switch s.ghAvailability {
        case .notInstalled:
            menu.addItem(disabled("gh CLI not found — brew install gh"))
            return
        case .notAuthenticated:
            menu.addItem(disabled("Run `gh auth login` to see PRs"))
            return
        case .error(let e):
            menu.addItem(disabled("GitHub: \(e)"))
            return
        case .unknown, .ok:
            break
        }
        let prs = s.visiblePRs
        if prs.isEmpty {
            menu.addItem(disabled(s.ghAvailability == .unknown ? "Loading…" : "No open PRs"))
            return
        }
        let groups = prs.map { (repo, pr) -> [NSMenuItem] in
            let ci = pr.ci.glyph.isEmpty ? "" : " \(pr.ci.glyph)"
            let draft = pr.isDraft ? " · draft" : ""
            let item = NSMenuItem(
                title: "#\(pr.number) \(pr.title)",
                action: #selector(StatusItemController.openURLAction(_:)),
                keyEquivalent: "")
            item.target = c
            item.representedObject = pr.url
            item.attributedTitle = twoTone(
                primary: "\(repo.repo.name) #\(pr.number)\(ci)",
                secondary: "  \(truncate(pr.title, 48))\(draft)")
            return [item]
        }
        addCapped(groups, to: menu)
    }

    // MARK: - Footer + controls

    private static func buildFooter(_ menu: NSMenu, _ s: Snapshot) {
        let visible = s.visibleRepos
        let clean = visible.filter { !$0.needsAttention }.count
        var text = "\(visible.count) repos · \(clean) clean"
        if let fetched = s.lastFetchAt {
            text += " · fetched \(ago(fetched))"
        }
        menu.addItem(disabled(text))
    }

    private static func buildControls(
        _ menu: NSMenu, _ s: Snapshot, _ c: StatusItemController
    ) {
        let myPRs = NSMenuItem(
            title: "Show Only My PRs",
            action: #selector(StatusItemController.togglePRScopeAction(_:)), keyEquivalent: "")
        myPRs.target = c
        myPRs.state = s.config.prScope == .mine ? .on : .off
        menu.addItem(myPRs)

        let autoFetch = NSMenuItem(
            title: "Auto-Fetch (every \(s.config.fetchIntervalMinutes)m)",
            action: #selector(StatusItemController.toggleAutoFetchAction(_:)), keyEquivalent: "")
        autoFetch.target = c
        autoFetch.state = s.config.fetchEnabled ? .on : .off
        menu.addItem(autoFetch)

        let refresh = NSMenuItem(
            title: "Refresh Now",
            action: #selector(StatusItemController.refreshAction(_:)), keyEquivalent: "r")
        refresh.target = c
        menu.addItem(refresh)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(StatusItemController.settingsAction(_:)), keyEquivalent: ",")
        settings.target = c
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: "Quit \(AppInfo.displayName)",
            action: #selector(StatusItemController.quitAction(_:)), keyEquivalent: "q")
        quit.target = c
        menu.addItem(quit)
    }

    // MARK: - Helpers

    private static func actionItem(
        _ title: String, _ action: Selector, _ payload: String, _ c: StatusItemController
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = c
        item.representedObject = payload
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func twoTone(primary: String, secondary: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let out = NSMutableAttributedString(
            string: primary,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        out.append(NSAttributedString(
            string: secondary,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return out
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    private static func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
