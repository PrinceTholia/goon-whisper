import SwiftUI

/// Menu-bar popover — same idea as KeepAwake: a few live controls, then Settings / Quit.
struct StatusPopoverView: View {
    @ObservedObject var controller: DictationController
    var onToggle: () -> Void
    var onSettings: () -> Void
    var onDictionary: () -> Void
    var onQuit: () -> Void

    private var speaking: Bool {
        controller.isRecording || controller.handsFreeUI
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: speaking ? "mic.fill" : "mic")
                    .font(.title2)
                    .foregroundColor(speaking ? .red : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper")
                        .font(.headline)
                    Text(speaking ? "Listening…" : "Hold Fn · tap for hands-free")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Button(action: onToggle) {
                Text(speaking ? "Stop Speaking" : "Start Speaking")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Toggle("AI Correction", isOn: $controller.useCorrection)
                .font(.callout)
            Text("Optional Groq polish after Whisper. Off is faster.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            HStack {
                Button("Settings", action: onSettings)
                Button("Dictionary", action: onDictionary)
                Spacer()
                Button("Quit", action: onQuit)
                    .foregroundColor(.secondary)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
    }
}
