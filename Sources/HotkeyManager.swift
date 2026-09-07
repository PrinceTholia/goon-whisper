import Foundation
import AppKit
import Carbon.HIToolbox

/// Known modifier key codes (for modifier-only hotkeys like Fn alone)
private let kVK_Function: UInt32 = 63
private let modifierKeyCodes: Set<UInt32> = [
    63, 55, 54, 56, 60, 58, 61, 59, 62, 57,
]

/// Hotkey configuration: keyCode + modifiers + mode (toggle or hold)
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var isHoldMode: Bool
    var isModifierOnly: Bool

    var displayString: String {
        if isModifierOnly {
            let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            if flags.contains(.function) { return "Fn" }
            if flags.contains(.control) { return "⌃" }
            if flags.contains(.option) { return "⌥" }
            if flags.contains(.shift) { return "⇧" }
            if flags.contains(.command) { return "⌘" }
            return "modifier"
        }

        var parts: [String] = []
        if modifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 { parts.append("⌃") }
        if modifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 { parts.append("⌥") }
        if modifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 { parts.append("⇧") }
        if modifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 { parts.append("⌘") }

        let keyNames: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "Return",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Delete): "Delete",
            UInt32(kVK_ForwardDelete): "Fwd Delete",
        ]
        let keyStr = keyNames[keyCode] ?? "Key\(keyCode)"
        return parts.joined() + keyStr
    }

    static let `default` = HotkeyConfig(
        keyCode: kVK_Function,
        modifiers: UInt(NSEvent.ModifierFlags.function.rawValue),
        isHoldMode: true,
        isModifierOnly: true
    )
}

/// Global hotkey manager.
/// For Fn (modifier-only + hold):
///   • Hold Fn  → push-to-talk (release to stop)
///   • Double-tap Fn → hands-free until Fn tapped again
class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var config: HotkeyConfig
    private var isHolding = false
    private var modifierKeyDown = false
    private var lastModifierPress: TimeInterval = 0
    private let doubleTapInterval: TimeInterval = 0.4

    /// Hands-free (double-tap) session — ignore key-up until next tap.
    private(set) var handsFreeActive = false
    private var pendingHoldStop: DispatchWorkItem?

    /// Enter/Return during hands-free → stop + paste + send Enter (set by AppDelegate).
    var onHandsFreeEnter: (() -> Void)?

    private var enterEventTap: CFMachPort?
    private var enterRunLoopSource: CFRunLoopSource?

    /// Clear hands-free without simulating a Fn tap (used by pill ✕ / stop).
    func endHandsFreeSession() {
        guard handsFreeActive else { return }
        handsFreeActive = false
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        lastModifierPress = 0
        setEnterTapEnabled(false)
        onHandsFreeChanged?(false)
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var isActive: (() -> Bool)?
    /// Fired when hands-free starts/stops (for UI hint).
    var onHandsFreeChanged: ((Bool) -> Void)?

    private let defaultsKey = "hotkey.config"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = .default
        }
    }

    var currentConfig: HotkeyConfig { config }

    func updateConfig(_ newConfig: HotkeyConfig) {
        config = newConfig
        if let data = try? JSONEncoder().encode(newConfig) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        handsFreeActive = false
        pendingHoldStop?.cancel()
        restartMonitors()
    }

    func start() { restartMonitors() }

    func stop() {
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        handsFreeActive = false
        setEnterTapEnabled(false)
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        tearDownEnterTap()
    }

    private func restartMonitors() {
        // Preserve callbacks; stop() clears hands-free — use careful restart
        let wasHF = handsFreeActive
        let enterCB = onHandsFreeEnter
        let down = onKeyDown
        let up = onKeyUp
        let active = isActive
        let hfChanged = onHandsFreeChanged

        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        tearDownEnterTap()

        onHandsFreeEnter = enterCB
        onKeyDown = down
        onKeyUp = up
        isActive = active
        onHandsFreeChanged = hfChanged
        handsFreeActive = wasHF

        let eventTypes: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventTypes) { [weak self] event in
            self?.handleEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventTypes) { [weak self] event in
            // Swallow Return in-process when hands-free (CG tap covers other apps)
            if let self, self.shouldSwallowHandsFreeEnter(event) {
                self.fireHandsFreeEnter()
                return nil
            }
            self?.handleEvent(event)
            return event
        }
        ensureEnterTap()
        setEnterTapEnabled(wasHF)
    }

    private func handleEvent(_ event: NSEvent) {
        if config.isModifierOnly {
            handleModifierEvent(event)
        } else {
            handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return }
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let configFlags = NSEvent.ModifierFlags(rawValue: config.modifiers)
            .intersection(.deviceIndependentFlagsMask)
        guard UInt32(event.keyCode) == config.keyCode, eventFlags == configFlags else { return }

        if event.type == .keyDown {
            if config.isHoldMode {
                guard !isHolding else { return }
                isHolding = true
                onKeyDown?()
            } else {
                onKeyDown?()
            }
        } else if event.type == .keyUp {
            if config.isHoldMode && isHolding {
                isHolding = false
                onKeyUp?()
            }
        }
    }

    /// Fn hybrid: hold = PTT, double-tap = hands-free toggle.
    private func handleModifierEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let configFlags = NSEvent.ModifierFlags(rawValue: config.modifiers)
        let isDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(configFlags)

        if isDown && !modifierKeyDown {
            modifierKeyDown = true
            handleModifierPressed()
        } else if !isDown && modifierKeyDown {
            modifierKeyDown = false
            handleModifierReleased()
        }
    }

    private func handleModifierPressed() {
        // Hands-free active → single tap stops
        if handsFreeActive {
            handsFreeActive = false
            pendingHoldStop?.cancel()
            lastModifierPress = 0
            setEnterTapEnabled(false)
            onHandsFreeChanged?(false)
            onKeyUp?()
            return
        }

        // Pure toggle mode (settings): keep old double-tap-to-start / tap-to-stop
        if !config.isHoldMode {
            if isActive?() == true {
                lastModifierPress = 0
                onKeyDown?()
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastModifierPress < doubleTapInterval {
                    lastModifierPress = 0
                    onKeyDown?()
                } else {
                    lastModifierPress = now
                }
            }
            return
        }

        // Hold mode + hybrid double-tap
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastModifierPress < doubleTapInterval {
            // Second tap → cancel pending hold-stop, enter hands-free
            pendingHoldStop?.cancel()
            pendingHoldStop = nil
            lastModifierPress = 0
            handsFreeActive = true
            onHandsFreeChanged?(true)
            setEnterTapEnabled(true)
            // Recording should already be running from first tap; if not, start
            if isActive?() != true {
                onKeyDown?()
            }
            return
        }

        lastModifierPress = now
        // First tap / hold start
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        if isActive?() != true {
            onKeyDown?()
        }
    }

    private func handleModifierReleased() {
        guard config.isHoldMode else { return }
        guard !handsFreeActive else { return } // ignore release during hands-free

        // Delay stop so a quick second tap can cancel and go hands-free
        pendingHoldStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.handsFreeActive else { return }
            self.onKeyUp?()
        }
        pendingHoldStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: work)
    }

    // MARK: - Hands-free Enter (Return / keypad Enter)

    private func shouldSwallowHandsFreeEnter(_ event: NSEvent) -> Bool {
        guard handsFreeActive, event.type == .keyDown else { return false }
        let code = UInt32(event.keyCode)
        guard code == UInt32(kVK_Return) || code == UInt32(kVK_ANSI_KeypadEnter) else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Plain Enter only — Shift+Enter stays newline in chat apps
        if mods.contains(.shift) || mods.contains(.command)
            || mods.contains(.option) || mods.contains(.control) {
            return false
        }
        return true
    }

    private func fireHandsFreeEnter() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handsFreeActive else { return }
            self.handsFreeActive = false
            self.pendingHoldStop?.cancel()
            self.pendingHoldStop = nil
            self.lastModifierPress = 0
            self.setEnterTapEnabled(false)
            self.onHandsFreeChanged?(false)
            self.onHandsFreeEnter?()
        }
    }

    private func ensureEnterTap() {
        if enterEventTap != nil { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                guard mgr.handsFreeActive else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
                    return Unmanaged.passUnretained(event)
                }
                let flags = event.flags
                if flags.contains(.maskShift) || flags.contains(.maskCommand)
                    || flags.contains(.maskAlternate) || flags.contains(.maskControl) {
                    return Unmanaged.passUnretained(event)
                }
                // Swallow Enter so chat doesn't send an empty message first
                mgr.fireHandsFreeEnter()
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            print("⚠️ Hands-free Enter tap unavailable (Accessibility?) — Enter-to-send disabled")
            return
        }
        enterEventTap = tap
        enterRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = enterRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    private func setEnterTapEnabled(_ on: Bool) {
        ensureEnterTap()
        if let tap = enterEventTap {
            CGEvent.tapEnable(tap: tap, enable: on)
        }
    }

    private func tearDownEnterTap() {
        if let tap = enterEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = enterRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        enterRunLoopSource = nil
        enterEventTap = nil
    }
}
