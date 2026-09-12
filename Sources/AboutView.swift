import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 48))
            Text("Whisper")
                .font(.title2).bold()
            Text("Version \(version)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Speak with Fn. Groq transcribes. Text pastes at the caret.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 300)
    }
}
