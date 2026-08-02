import AppKit
import ApplicationServices

/// Raises the window of another app whose title mentions a token (the
/// agent's working-directory name) via the Accessibility API. Covers hosts
/// with no tty scripting: IDEs (VS Code, JetBrains, Zed, Xcode, Cursor) and
/// terminals like Warp, Alacritty, Kitty, Ghostty — their window titles
/// almost always carry the project/cwd name.
@MainActor
enum AXWindowFocus {

    /// False when Accessibility isn't granted (the system prompts the first
    /// time) or no window title matches — caller degrades to app activation.
    static func raise(app: NSRunningApplication, titleToken: String) -> Bool {
        // Literal key: the kAXTrustedCheckOptionPrompt global is rejected by
        // Swift 6 strict concurrency (shared mutable state).
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
                == .success,
            let windows = windowsRef as? [AXUIElement]
        else { return false }

        let token = titleToken.lowercased()
        for window in windows {
            var titleRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    == .success,
                let title = titleRef as? String,
                title.lowercased().contains(token)
            else { continue }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return true
        }
        return false
    }
}
