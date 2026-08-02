# typed: true
# frozen_string_literal: true

# Menubar overview of git repos, Claude Code agents, worktrees, and GitHub PRs.
class Agentsandrepos < Formula
  desc "Menubar overview of git repos, Claude Code agents, worktrees, and GitHub PRs"
  homepage "https://github.com/millisecond/agentsandrepos"
  url "https://github.com/millisecond/agentsandrepos/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_AFTER_TAGGING"
  license "MIT"
  head "https://github.com/millisecond/agentsandrepos.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/agentsandrepos"
  end

  service do
    run [opt_bin/"agentsandrepos"]
    # Restart on crashes, but not when a copy exits cleanly because another
    # instance already holds the single-instance lock.
    keep_alive successful_exit: false
    process_type :interactive
    log_path var/"log/agentsandrepos.log"
    error_log_path var/"log/agentsandrepos.log"
  end

  test do
    assert_match "agentsandrepos", shell_output("#{bin}/agentsandrepos --version")
  end
end
