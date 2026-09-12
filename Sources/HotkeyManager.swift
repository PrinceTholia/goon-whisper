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
///   • Fn down → always start recording
///   • Quick tap (release before holdThreshold) → continuous hands-free
///   • Hold past threshold → push-to-talk (release stops + paste)
///   • During hands-free: tap Fn / Enter sends; Esc or ✕ cancels
class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var config: HotkeyConfig
    private var isHolding = false
    private var modifierKeyDown = false
    /// Event-time of matching Fn-down (`NSEvent.timestamp`). 0 = no matching press.
    private var modifierDownAt: TimeInterval = 0
    /// How long Fn may stay down and still count as a *tap* (hands-free).
    /// Longer than this → push-to-talk (stop on release).
    /// 0.28s was too tight — normal finger taps often exceeded it and became PTT by mistake.
    private let holdThreshold: TimeInterval = 0.45
    private var lastModifierPress: TimeInterval = 0
    /// After stopping hands-free on Fn-down, ignore the matching key-up (do not re-enter HF).
    private var suppressNextRelease = false
    /// Esc aborts in-flight STT / correction after stop (tap stays armed).
    private var inFlightEscArmed = false

    /// Hands-free (single-tap) continuous session.
    private(set) var handsFreeActive = false
    private var pendingHoldStop: DispatchWorkItem?

    /// Enter/Return during hands-free → stop + paste + send Enter.
    var onHandsFreeEnter: (() -> Void)?
    /// Escape during hands-free → cancel (no paste).
    var onHandsFreeCancel: (() -> Void)?
    /// Escape while transcribing / correcting / pasting → abort that generation.
    var onProcessingCancel: (() -> Void)?

    private var enterEventTap: CFMachPort?
    private var enterRunLoopSource: CFRunLoopSource?

    /// Clear hands-free without simulating a Fn tap (used by pill ✕ / stop / Esc).
    func endHandsFreeSession() {
        guard handsFreeActive else { return }
        handsFreeActive = false
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        lastModifierPress = 0
        if modifierKeyDown {
            suppressNextRelease = true
        }
        syncKeyTap()
        onHandsFreeChanged?(false)
    }

    /// Keep the CGEvent tap alive so Esc can abort STT after stop.
    func setInFlightEscArmed(_ on: Bool) {
        inFlightEscArmed = on
        syncKeyTap()
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
        suppressNextRelease = false
        modifierDownAt = 0
        restartMonitors()
    }

    func start() { restartMonitors() }

    func stop() {
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        handsFreeActive = false
        inFlightEscArmed = false
        suppressNextRelease = false
        modifierDownAt = 0
        syncKeyTap()
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        tearDownHandsFreeKeyTap()
    }

    private func restartMonitors() {
        let wasHF = handsFreeActive
        let enterCB = onHandsFreeEnter
        let cancelCB = onHandsFreeCancel
        let processingCB = onProcessingCancel
        let down = onKeyDown
        let up = onKeyUp
        let active = isActive
        let hfChanged = onHandsFreeChanged

        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        tearDownHandsFreeKeyTap()

        onHandsFreeEnter = enterCB
        onHandsFreeCancel = cancelCB
        onProcessingCancel = processingCB
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
            if let self {
                if self.shouldSwallowHandsFreeEnter(event) {
                    self.fireHandsFreeEnter()
                    return nil
                }
                if self.shouldSwallowHandsFreeEscape(event) {
                    self.fireHandsFreeCancel()
                    return nil
                }
                if self.shouldSwallowInFlightEscape(event) {
                    self.fireProcessingCancel()
                    return nil
                }
            }
            self?.handleEvent(event)
            return event
        }
        ensureHandsFreeKeyTap()
        syncKeyTap()
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

    /// Fn: down always records; quick release → hands-free; long hold → PTT stop on release.
    private func handleModifierEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let configFlags = NSEvent.ModifierFlags(rawValue: config.modifiers)
        let isDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(configFlags)

        if isDown && !modifierKeyDown {
            modifierKeyDown = true
            handleModifierPressed(at: event.timestamp)
        } else if !isDown && modifierKeyDown {
            modifierKeyDown = false
            handleModifierReleased(at: event.timestamp)
        }
    }

    private func handleModifierPressed(at timestamp: TimeInterval) {
        // Hands-free active → tap Fn stops (paste, no auto-Enter)
        if handsFreeActive {
            // Capture focus NOW (before any async hop) — same rule as Enter
            FocusMemory.capture()
            handsFreeActive = false
            pendingHoldStop?.cancel()
            lastModifierPress = 0
            // Matching Fn-up must not re-enter hands-free with no recording.
            suppressNextRelease = true
            modifierDownAt = 0
            syncKeyTap()
            onHandsFreeChanged?(false)
            onKeyUp?()
            return
        }

        // Pure toggle mode (settings): each Fn press toggles recording
        if !config.isHoldMode {
            lastModifierPress = 0
            modifierDownAt = timestamp
            onKeyDown?()
            return
        }

        // Hold mode: classify tap/hold from *event* time, not wall-clock after engine.start().
        modifierDownAt = timestamp
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        if isActive?() != true {
            onKeyDown?()
        }
    }

    private func handleModifierReleased(at timestamp: TimeInterval) {
        if suppressNextRelease {
            suppressNextRelease = false
            modifierDownAt = 0
            return
        }
        guard config.isHoldMode else { return }
        guard !handsFreeActive else { return }
        // Unmatched Fn-up (never pressed / already consumed) is not a long hold.
        guard modifierDownAt > 0 else { return }

        let held = timestamp - modifierDownAt
        modifierDownAt = 0
        if held < holdThreshold {
            // Quick tap → keep recording as continuous hands-free
            handsFreeActive = true
            onHandsFreeChanged?(true)
            syncKeyTap()
            print("🎙️ Single-tap Fn → hands-free continuous")
        } else {
            // Held long enough → classic PTT stop on release
            onKeyUp?()
        }
    }

    // MARK: - Hands-free Enter / Escape

    private func shouldSwallowHandsFreeEnter(_ event: NSEvent) -> Bool {
        guard handsFreeActive, event.type == .keyDown else { return false }
        let code = UInt32(event.keyCode)
        guard code == UInt32(kVK_Return) || code == UInt32(kVK_ANSI_KeypadEnter) else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.shift) || mods.contains(.command)
            || mods.contains(.option) || mods.contains(.control) {
            return false
        }
        return true
    }

    private func shouldSwallowHandsFreeEscape(_ event: NSEvent) -> Bool {
        guard handsFreeActive, event.type == .keyDown else { return false }
        return UInt32(event.keyCode) == UInt32(kVK_Escape)
    }

    private func shouldSwallowInFlightEscape(_ event: NSEvent) -> Bool {
        guard inFlightEscArmed, event.type == .keyDown else { return false }
        return UInt32(event.keyCode) == UInt32(kVK_Escape)
    }

    private func fireHandsFreeEnter() {
        // Remember caret app the instant Enter is pressed — before async / window switches
        FocusMemory.capture()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handsFreeActive else { return }
            self.handsFreeActive = false
            self.pendingHoldStop?.cancel()
            self.pendingHoldStop = nil
            self.lastModifierPress = 0
            self.syncKeyTap()
            self.onHandsFreeChanged?(false)
            self.onHandsFreeEnter?()
        }
    }

    private func fireHandsFreeCancel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.handsFreeActive else { return }
            self.handsFreeActive = false
            self.pendingHoldStop?.cancel()
            self.pendingHoldStop = nil
            self.lastModifierPress = 0
            self.syncKeyTap()
            self.onHandsFreeChanged?(false)
            self.onHandsFreeCancel?()
        }
    }

    private func fireProcessingCancel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inFlightEscArmed else { return }
            self.onProcessingCancel?()
        }
    }

    private func ensureHandsFreeKeyTap() {
        if enterEventTap != nil { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    mgr.syncKeyTap()
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == Int64(kVK_Escape) {
                    if mgr.handsFreeActive {
                        mgr.fireHandsFreeCancel()
                        return nil
                    }
                    if mgr.inFlightEscArmed {
                        mgr.fireProcessingCancel()
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard mgr.handsFreeActive else {
                    return Unmanaged.passUnretained(event)
                }
                guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
                    return Unmanaged.passUnretained(event)
                }
                let flags = event.flags
                if flags.contains(.maskShift) || flags.contains(.maskCommand)
                    || flags.contains(.maskAlternate) || flags.contains(.maskControl) {
                    return Unmanaged.passUnretained(event)
                }
                mgr.fireHandsFreeEnter()
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            print("⚠️ Hands-free key tap unavailable (Accessibility?) — Enter/Esc hooks limited")
            return
        }
        enterEventTap = tap
        enterRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = enterRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    private func syncKeyTap() {
        ensureHandsFreeKeyTap()
        let on = handsFreeActive || inFlightEscArmed
        if let tap = enterEventTap {
            CGEvent.tapEnable(tap: tap, enable: on)
        }
    }

    private func tearDownHandsFreeKeyTap() {
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
