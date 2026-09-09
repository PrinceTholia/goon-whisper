import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Remembers which app had focus at capture time (for paste targeting).
/// Capture at the moment the user **stops** (Fn / Enter / ■) — not later during STT —
/// then activate that app again before paste so a mid-wait window switch doesn’t steal ⌘V.
enum FocusMemory {
    private static var app: NSRunningApplication?
    private static let lock = NSLock()

    static func capture() {
        let front = NSWorkspace.shared.frontmostApplication
        lock.lock()
        app = front
        lock.unlock()
        if let name = front?.localizedName {
            print("📌 Focus captured: \(name)")
        }
    }

    static var current: NSRunningApplication? {
        lock.lock()
        defer { lock.unlock() }
        return app
    }

    /// Frontmost app name at capture time — light vocabulary bias (like Gemini screen context lite).
    static var lastAppName: String? {
        current?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bring the remembered app forward so paste / Enter hit the caret from stop time.
    @discardableResult
    static func activateCaptured() -> NSRunningApplication? {
        guard let target = current,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return current
        }
        if !target.isActive {
            target.activate(options: [.activateIgnoringOtherApps])
        }
        return target
    }
}

enum PasteOutcome: Equatable {
    case inserted
    case copiedOnly
}

/// Clipboard + auto-paste (known-good behavior).
///
/// Critical: never open System Settings during paste — that steals focus and
/// makes ⌘V land nowhere. Also: do not gate on `AXIsProcessTrusted()` alone;
/// ad-hoc builds often report false even when Accessibility is enabled.
///
/// Paste strategies are **mutually exclusive** — never stack AX + ⌘V + System Events
/// (that caused double-paste in Chrome/Spotify/Electron).
enum Paster {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "org.alacritty",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]

    private static let didPromptKey = "whisper.didPromptAccessibility"
    private static let didAttemptPromptKey = "whisper.didAttemptAXPrompt"
    private static let exeTokenKey = "whisper.executableToken"

    /// Serializes paste so overlapping finishes can't fire two ⌘Vs.
    private static let pasteLock = NSLock()
    private static var pasteGeneration: UInt64 = 0

    /// True when Accessibility APIs actually respond (stronger than AXIsProcessTrusted for ad-hoc).
    static var canUseAccessibilityAPIs: Bool {
        if AXIsProcessTrusted() { return true }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        // .apiDisabled means TCC denied this binary; anything else means APIs are usable
        return err != .apiDisabled
    }

    static var isAccessibilityTrusted: Bool { canUseAccessibilityAPIs }

    @discardableResult
    static func paste(_ text: String) -> PasteOutcome {
        guard !text.isEmpty else { return .copiedOnly }

        pasteLock.lock()
        pasteGeneration &+= 1
        let generation = pasteGeneration
        pasteLock.unlock()

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let target = FocusMemory.activateCaptured()
        if target?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return .copiedOnly
        }

        if isTerminalApp(target) {
            pasteIntoTerminal(app: target, generation: generation)
            return .inserted
        }

        // WebViews / Electron: AX insert is unreliable (false success or no-op).
        // Activate remembered app first, then single delayed ⌘V — never follow with System Events.
        if prefersCommandVOnly(target) {
            pasteCommandVOnly(delay: 0.22, generation: generation, label: target?.localizedName ?? "web")
            return .inserted
        }

        // Native apps: try AX once; if that fails, ⌘V once. Never both backups.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard Self.isCurrentPaste(generation) else { return }
            FocusMemory.activateCaptured()
            if insertViaAccessibility(text) {
                print("✅ Paste via AX insert")
                return
            }
            guard Self.isCurrentPaste(generation) else { return }
            simulateCommandV()
            print("✅ Paste via ⌘V")
        }
        return .inserted
    }

    private static func isCurrentPaste(_ generation: UInt64) -> Bool {
        pasteLock.lock()
        let ok = pasteGeneration == generation
        pasteLock.unlock()
        return ok
    }

    private static func pasteCommandVOnly(delay: TimeInterval, generation: UInt64, label: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isCurrentPaste(generation) else { return }
            FocusMemory.activateCaptured()
            // Brief beat so the target app is frontmost before ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard isCurrentPaste(generation) else { return }
                simulateCommandV()
                print("✅ \(label) paste via ⌘V only")
            }
        }
    }

    private static func isWhatsApp(_ app: NSRunningApplication?) -> Bool {
        let id = (app?.bundleIdentifier ?? "").lowercased()
        if id.contains("whatsapp") { return true }
        let name = (app?.localizedName ?? "").lowercased()
        return name.contains("whatsapp")
    }

    /// Browsers, Electron, and similar — ⌘V only (same class as WhatsApp composer).
    private static func prefersCommandVOnly(_ app: NSRunningApplication?) -> Bool {
        if isWhatsApp(app) { return true }
        let id = (app?.bundleIdentifier ?? "").lowercased()
        let name = (app?.localizedName ?? "").lowercased()
        let needles = [
            "chrome", "chromium", "firefox", "safari", "edge", "brave", "opera", "arc",
            "spotify", "discord", "slack", "notion", "figma", "electron",
            "code", "cursor", "spotify", "microsoft.edgemac", "com.apple.Safari",
            "company.thebrowser.Browser", "browser",
        ]
        if needles.contains(where: { id.contains($0) || name.contains($0) }) { return true }
        return false
    }

    private static func isTerminalApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        if terminalBundleIDs.contains(id) { return true }
        let name = (app?.localizedName ?? "").lowercased()
        return name.contains("terminal") || name.contains("iterm")
            || name.contains("kitty") || name.contains("warp")
            || name.contains("alacritty") || name.contains("ghostty")
            || name.contains("wezterm") || name.contains("hyper")
    }

    private static func pasteIntoTerminal(app: NSRunningApplication?, generation: UInt64) {
        let processName = app?.localizedName ?? "Terminal"
        app?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard isCurrentPaste(generation) else { return }
            // One strategy only — stop after the first success
            if pasteViaMenu(processName: processName) {
                print("✅ Terminal paste via Edit → Paste")
                return
            }
            if pasteViaSystemEvents(processName: processName) {
                print("✅ Terminal paste via System Events")
                return
            }
            simulateCommandV()
            print("✅ Terminal paste via ⌘V")
        }
    }

    @discardableResult
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return false }

        let el = focusedRef as! AXUIElement
        if AXUIElementSetAttributeValue(
            el, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success {
            return true
        }
        return false
    }

    @discardableResult
    private static func pasteViaMenu(processName: String) -> Bool {
        let escaped = escapeAppleScript(processName)
        let script = """
        tell application "System Events"
          tell process "\(escaped)"
            try
              click menu item "Paste" of menu "Edit" of menu bar 1
              return "ok"
            end try
            try
              keystroke "v" using command down
              return "ok"
            end try
          end tell
        end tell
        return "fail"
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { return false }
        return result?.stringValue == "ok"
    }

    private static func simulateCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }

    /// Plain Return / Enter after paste (hands-free “send”).
    static func simulateReturn() {
        FocusMemory.activateCaptured()
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0
        let key = CGKeyCode(kVK_Return)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else {
            return
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
        print("✅ Simulated Return (send)")
    }

    @discardableResult
    private static func pasteViaSystemEvents(processName: String?, activate: Bool = true) -> Bool {
        let script: String
        if let processName {
            let escaped = escapeAppleScript(processName)
            let front = activate ? "set frontmost to true\n                " : ""
            script = """
            tell application "System Events"
              tell process "\(escaped)"
                \(front)keystroke "v" using command down
              end tell
            end tell
            """
        } else {
            script = """
            tell application "System Events"
              keystroke "v" using command down
            end tell
            """
        }
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            print("⚠️ System Events paste: \(err)")
            return false
        }
        return true
    }

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launch-only soft prompt — never during paste.
    static func refreshTrustPromptIfBinaryChanged() {
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            promptAccessibilityOnce()
            return
        }
        let token = "\(modified.timeIntervalSince1970)-\(size)"
        if UserDefaults.standard.string(forKey: exeTokenKey) != token {
            UserDefaults.standard.set(token, forKey: exeTokenKey)
            UserDefaults.standard.set(false, forKey: didPromptKey)
            UserDefaults.standard.set(false, forKey: didAttemptPromptKey)
        }
        promptAccessibilityOnce()
    }

    static func promptAccessibilityOnce() {
        if AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: didPromptKey)
            return
        }
        if UserDefaults.standard.bool(forKey: didAttemptPromptKey) { return }
        UserDefaults.standard.set(true, forKey: didAttemptPromptKey)
        // Prompt dialog only — do not open System Settings window (steals focus later)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: didPromptKey)
        }
    }

    static func warmAutomationPermission() {
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: """
            tell application "System Events"
              return name of first process whose frontmost is true
            end tell
            """)?.executeAndReturnError(&err)
            if let err { print("⚠️ Automation warm-up: \(err)") }
        }
    }
}

extension Notification.Name {
    static let whisperNeedsAccessibilityForPaste = Notification.Name("whisperNeedsAccessibilityForPaste")
    static let whisperNeedsAutomationForPaste = Notification.Name("whisperNeedsAutomationForPaste")
}
