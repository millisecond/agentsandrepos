# typed: true
# frozen_string_literal: true

# Cask for the prebuilt app bundle (RepoBar-style): `brew install --cask
# agentsandrepos` drops the .app in /Applications and links the CLI; the user
# opens the app and flips "Start at login" in Settings (SMAppService).
# Lives in the tap's Casks/ directory. Built by packaging/make-app.sh.
cask "agentsandrepos" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_MAKE_APP"

  url "https://github.com/millisecond/agentsandrepos/releases/download/v#{version}/agentsandrepos-#{version}.zip"
  name "Agents & Repos"
  desc "Menubar overview of git repos, Claude Code agents, worktrees, and GitHub PRs"
  homepage "https://github.com/millisecond/agentsandrepos"

  depends_on macos: :sonoma

  app "Agents & Repos.app"
  binary "#{appdir}/Agents & Repos.app/Contents/MacOS/agentsandrepos"

  # Menubar app: launch right after install so it appears without an extra
  # step. (Would need removing if this ever moves to homebrew/cask — official
  # casks don't auto-launch.)
  postflight do
    system_command "/usr/bin/open", args: ["#{appdir}/Agents & Repos.app"]
  end

  zap trash: [
    "~/.config/agentsandrepos",
    "~/Library/Caches/com.millisecond.agentsandrepos",
    "~/Library/HTTPStorages/com.millisecond.agentsandrepos",
    "~/Library/Preferences/com.millisecond.agentsandrepos.plist",
    "~/Library/Saved Application State/com.millisecond.agentsandrepos.savedState",
  ]

  caveats <<~EOS
    To start it at login, open the app and enable "Start at login" in
    Settings.
  EOS
end
