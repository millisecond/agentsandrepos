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

  # No auto-launch postflight: Homebrew 6 runs install steps inside a sandbox
  # that can't reach RunningBoard, so `open` fails there (kLSUnknownErr,
  # "Couldn't communicate with a helper application") and takes the whole
  # install down with it. The README's install command (also the in-app
  # upgrade command) ends with `open -a` instead.

  # Stop the running app on uninstall and upgrade — otherwise it keeps
  # running from the deleted bundle and holds the single-instance lock.
  # on_upgrade: brew skips `signal` during upgrade/reinstall without it.
  # Array form on purpose: brew replays the OLD cask from the JSON it saved
  # at install, which turns a bare :signal into "signal", and it ignores a
  # String there. An array survives (Homebrew 6).
  uninstall signal:     [["TERM", "com.millisecond.agentsandrepos"]],
            on_upgrade: [:signal]

  zap trash: [
    "~/.config/agentsandrepos",
    "~/Library/Caches/com.millisecond.agentsandrepos",
    "~/Library/HTTPStorages/com.millisecond.agentsandrepos",
    "~/Library/Preferences/com.millisecond.agentsandrepos.plist",
    "~/Library/Saved Application State/com.millisecond.agentsandrepos.savedState",
  ]

  caveats <<~EOS
    Launch it with:
      open -a "Agents & Repos"
    To start it at login, open the app and enable "Start at login" in
    Settings.
  EOS
end
