import SwiftUI

/// Shared point sizes — fixed AppKit points across displays.
private enum FlowPillMetrics {
    static let height: CGFloat = 32
    static let recordingWidth: CGFloat = 104
    static let handsFreeWidth: CGFloat = 148
    static let statusMaxWidth: CGFloat = 132
    static let horizontalPad: CGFloat = 10
    static let panelWidth: CGFloat = 160
    static let panelHeight: CGFloat = 40
    static let waveMaxBar: CGFloat = 16
    static let stroke: CGFloat = 1.25
    static let barCount = 14
}

/// Wispr Flow–style floating pill.
/// Hold Fn: continuous waveform. Tap Fn hands-free: ✕ | wave | stop (Esc cancels).
struct FloatingStatusView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ZStack {
            content
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
        .frame(width: FlowPillMetrics.panelWidth, height: FlowPillMetrics.panelHeight)
        .animation(.easeInOut(duration: 0.16), value: stageKey)
    }

    private var stageKey: String {
        switch controller.stage {
        case .idle: return "idle"
        case .recording: return controller.handsFreeUI ? "recHF" : "rec"
        case .transcribing: return "tx"
        case .correcting: return "corr"
        case .done: return "done"
        case .copied: return "copy"
        case .error: return "err"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .recording:
            FlowRecordingPill(
                recorder: controller.recorder,
                handsFree: controller.handsFreeUI,
                onCancel: {
                    HotkeyManager.shared.endHandsFreeSession()
                    controller.cancelRecording()
                },
                onStop: {
                    HotkeyManager.shared.endHandsFreeSession()
                    controller.stop()
                }
            )
        case .transcribing, .correcting:
            FlowStatusPill(text: "Cleaning up…", sparkle: true)
        case .done:
            Color.clear.frame(width: 1, height: 1)
        case .copied:
            FlowStatusPill(text: "Copied — ⌘V", sparkle: false)
        case .error(let msg):
            FlowStatusPill(text: msg, sparkle: false, warn: true)
        case .idle:
            Color.clear
        }
    }
}

private struct FlowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.92))
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: FlowPillMetrics.stroke)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 6, y: 2)
    }
}

/// Continuous waveform (never swaps to dots mid-utterance).
/// Hands-free adds ✕ (cancel) and ■ (stop & paste).
struct FlowRecordingPill: View {
    @ObservedObject var recorder: AudioRecorder
    var handsFree: Bool
    var onCancel: () -> Void
    var onStop: () -> Void

    @State private var bars: [CGFloat] = Array(repeating: 0.12, count: FlowPillMetrics.barCount)
    private let timer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            if handsFree {
                FlowCircleButton(systemName: "xmark", action: onCancel)
            }

            waveform
                .frame(
                    width: handsFree ? 72 : (FlowPillMetrics.recordingWidth - FlowPillMetrics.horizontalPad * 2),
                    height: FlowPillMetrics.waveMaxBar
                )

            if handsFree {
                FlowCircleButton(systemName: "stop.fill", action: onStop)
            }
        }
        .padding(.horizontal, handsFree ? 8 : FlowPillMetrics.horizontalPad)
        .frame(
            width: handsFree ? FlowPillMetrics.handsFreeWidth : FlowPillMetrics.recordingWidth,
            height: FlowPillMetrics.height
        )
        .modifier(FlowChrome())
        .onReceive(timer) { _ in
            tickBars()
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2.0) {
            ForEach(bars.indices, id: \.self) { i in
                let mid = CGFloat(bars.count - 1) / 2
                let edge = mid > 0 ? (1 - abs(CGFloat(i) - mid) / mid) : 1
                let h = max(2.5, bars[i] * FlowPillMetrics.waveMaxBar * (0.5 + 0.5 * edge))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.55 + Double(bars[i]) * 0.4))
                    .frame(width: 2.0, height: h)
                    .animation(.easeOut(duration: 0.08), value: bars[i])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Smooth scrolling meters — never tear down the view when quiet.
    private func tickBars() {
        let lvl = CGFloat(recorder.level)
        // Soft floor so silence still shows a gentle pulse, not a hard reset
        let floor: CGFloat = 0.06
        let shaped = max(floor, min(1, lvl * 2.4))
        // Light motion even when quiet (Wispr-like alive idle)
        let breathe = 0.85 + 0.15 * sin(Date().timeIntervalSinceReferenceDate * 3.2)
        let target = shaped * CGFloat(breathe)

        var next = Array(bars.dropFirst())
        let prev = next.last ?? floor
        // Heavier smoothing = less glitchy jumps
        let smoothed = prev * 0.55 + target * 0.45
        next.append(smoothed)
        // Slight neighbor bleed for a wavier silhouette
        if next.count >= 3 {
            let i = next.count - 2
            next[i] = next[i] * 0.7 + next[i - 1] * 0.15 + next[i + 1] * 0.15
        }
        bars = next
    }
}

/// Retina-crisp control: even point sizes + stroked ring (matches Wispr X / confirm).
private struct FlowCircleButton: View {
    let systemName: String
    let action: () -> Void

    private let diameter: CGFloat = 20

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(white: 0.22).opacity(0.95))
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                Image(systemName: systemName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .imageScale(.medium)
                    .foregroundStyle(Color.white.opacity(0.95))
            }
            .frame(width: diameter, height: diameter)
            .compositingGroup()
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(systemName == "xmark" ? "Cancel" : "Stop and paste")
    }
}

struct FlowStatusPill: View {
    let text: String
    var sparkle: Bool = false
    var warn: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if sparkle {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(warn ? Color(red: 1.0, green: 0.78, blue: 0.45) : Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, FlowPillMetrics.horizontalPad)
        .frame(minWidth: 100, maxWidth: FlowPillMetrics.statusMaxWidth,
               minHeight: FlowPillMetrics.height, maxHeight: FlowPillMetrics.height)
        .modifier(FlowChrome())
    }
}

typealias RecordingPill = FlowRecordingPill
typealias StatusPill = FlowStatusPill
