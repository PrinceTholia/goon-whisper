import AppKit
import SwiftUI
import Combine
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let controller = DictationController()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var panelHosting: NSHostingView<FloatingStatusView>!
    private var hidePanelWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private var settingsWindow: NSWindow?
    private var dictionaryWindow: NSWindow?
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        KeyStore.prewarm()
        FeedbackSound.preload()
        Self.syncCloudProviders()
        setupStatusItem()
        setupPanel()
        setupHotkey()

        controller.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                guard let self = self else { return }
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: Self.iconName(for: stage),
                    accessibilityDescription: "Whisper"
                )
                if stage == .idle {
                    self.hidePanel()
                } else {
                    self.showPanel()
                }
            }
            .store(in: &cancellables)

        // Backup: beeps fire on isRecording; never rely only on stage for HUD visibility
        controller.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                if recording { self?.showPanel() }
            }
            .store(in: &cancellables)

        controller.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.statusItem.button?.toolTip = s }
            .store(in: &cancellables)

        // Stop macOS Dictation from stealing double-Fn (live text + music pause)
        SystemConflictGuard.disableSystemFnDictationIfNeeded(showAlertIfChanged: true)

        // New ad-hoc binary → re-prompt Accessibility; warm Automation for System Events paste
        Paster.refreshTrustPromptIfBinaryChanged()
        Paster.warmAutomationPermission()

        NotificationCenter.default.publisher(for: .dictionaryAutoLearned)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let summary = note.userInfo?["summary"] as? String else { return }
                self?.controller.status = "📚 Learned: \(summary)"
            }
            .store(in: &cancellables)

        // Do NOT auto-open Settings on paste failure — that steals focus and breaks paste.
        // User can use menu → Fix Accessibility… when needed.
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Whisper")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 280, height: 210)
        pop.contentViewController = NSHostingController(rootView: StatusPopoverView(
            controller: controller,
            onToggle: { [weak self] in
                self?.popover.performClose(nil)
                self?.toggleAction()
            },
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            },
            onDictionary: { [weak self] in
                self?.popover.performClose(nil)
                self?.openDictionary()
            },
            onQuit: { NSApp.terminate(nil) }
        ))
        popover = pop
        updateStates()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateStates()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { updateStates() }

    private func updateStates() {
        let bt = UserDefaults.standard.bool(forKey: "backtrackEnabled")
        if controller.useBacktrack != bt { controller.useBacktrack = bt }

        if UserDefaults.standard.object(forKey: "useCorrection") != nil {
            let corrUD = UserDefaults.standard.bool(forKey: "useCorrection")
            if controller.useCorrection != corrUD { controller.useCorrection = corrUD }
        }

        Self.syncCloudProviders()

        if !UserDefaults.standard.bool(forKey: "groqLargeV3Migrate") {
            let groq = STTRegistry.provider(id: "groq")
            let saved = STTSettings.savedModel(for: groq)
            if saved.isEmpty || saved.contains("turbo") {
                STTSettings.saveModel("whisper-large-v3", for: groq)
            }
            UserDefaults.standard.set(true, forKey: "groqLargeV3Migrate")
        }
    }

    /// Product path is Groq-only — pin STT + correction regardless of leftover UserDefaults.
    private static func syncCloudProviders() {
        STTSettings.providerID = "groq"
        LLMSettings.providerID = "groq"
    }

    @objc private func toggleAction() {
        if controller.isRecording || controller.handsFreeUI || controller.isBusy {
            HotkeyManager.shared.endHandsFreeSession()
            controller.handsFreeUI = false
            if controller.isRecording || controller.stage == .recording {
                controller.stop()
            } else if controller.processing {
                // Menu "Stop" during cleanup: leave the in-flight generation to finish.
            }
        } else {
            controller.start()
        }
    }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Whisper Settings"
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openDictionary() {
        if dictionaryWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Custom Dictionary"
            w.contentView = NSHostingView(rootView: DictionaryView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            dictionaryWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dictionaryWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let win = notification.object as? NSWindow
        if win === settingsWindow || win === dictionaryWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Floating status panel

    private static func iconName(for stage: Stage) -> String {
        switch stage {
        case .recording: return "mic.fill"
        case .transcribing: return "waveform.circle"
        case .correcting: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .copied: return "doc.on.clipboard"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "mic"
        }
    }

    private func setupPanel() {
        panelHosting = NSHostingView(rootView: FloatingStatusView(controller: controller))
        let rect = NSRect(x: 0, y: 0, width: 168, height: 40)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = panelHosting
        // Keep in the window list (alpha 0) so SwiftUI keeps updating — orderOut caused blank HUD races
        panel.orderFrontRegardless()
    }

    /// Screen that currently contains the mouse — so the pill follows the active display.
    private func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func showPanel() {
        hidePanelWork?.cancel()
        hidePanelWork = nil

        let screen = screenUnderCursor()
        let f = screen.visibleFrame
        let wide = controller.handsFreeUI || HotkeyManager.shared.handsFreeActive
        let size = NSSize(width: wide ? 168 : 140, height: 40)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: f.midX - size.width / 2,
            y: f.minY + 40
        ))
        panel.ignoresMouseEvents = !wide
        // Re-bind root view so the pill never sticks on a blank idle frame after hide
        panelHosting.rootView = FloatingStatusView(controller: controller)
        panelHosting.needsLayout = true
        panelHosting.needsDisplay = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        hidePanelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.controller.isRecording,
               self.controller.stage == .idle {
                self.panel.alphaValue = 0
                self.panel.ignoresMouseEvents = true
            }
        }
        hidePanelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Global hotkey

    private func setupHotkey() {
        let mgr = HotkeyManager.shared

        mgr.onKeyDown = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Hold / single-tap hands-free both start; toggle() for pure toggle mode
                if HotkeyManager.shared.currentConfig.isHoldMode {
                    if HotkeyManager.shared.handsFreeActive {
                        if !self.controller.isRecording {
                            self.controller.start()
                        }
                    } else {
                        self.controller.start()
                    }
                } else {
                    self.controller.toggle()
                }
            }
        }

        mgr.onKeyUp = { [weak self] in
            // Freeze focus before async stop (hold-release or hands-free Fn)
            FocusMemory.capture()
            DispatchQueue.main.async {
                self?.controller.stop(sendEnterAfterPaste: false, recaptureFocus: false)
            }
        }

        mgr.onHandsFreeEnter = { [weak self] in
            // Focus already frozen when Enter was swallowed — do not recapture after async
            self?.controller.stop(sendEnterAfterPaste: true, recaptureFocus: false)
        }

        mgr.onHandsFreeCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.controller.cancelRecording()
            }
        }

        mgr.onProcessingCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.controller.cancelRecording()
            }
        }

        mgr.isActive = { [weak self] in
            self?.controller.isRecording ?? false
        }

        mgr.onHandsFreeChanged = { [weak self] active in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.controller.handsFreeUI = active
                self.panel.ignoresMouseEvents = !active
                if active {
                    self.controller.status = "Hands-free — Enter sends · Esc/✕ cancel · ■ or Fn stop"
                    self.showPanel()
                } else if self.controller.status.hasPrefix("Hands-free") {
                    self.controller.status = ""
                }
            }
        }

        mgr.start()
    }
}

private func open(_ urlString: String) {
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}
