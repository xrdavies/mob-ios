import SwiftUI

/// Settings → Log: the in-memory debug log, newest at the bottom, with Copy and Clear.
struct LogView: View {
    private var log: Log { Log.shared }
    /// Lines copied, shown for a moment so the tap visibly did something.
    @State private var copied: Int?

    var body: some View {
        ScrollViewReader { proxy in
            List(log.entries) { e in
                Text(e.line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(e.error ? .red : .primary)
                    .textSelection(.enabled)
                    .id(e.id)
            }
            .listStyle(.plain)
            .overlay { if log.entries.isEmpty { Text("Nothing logged yet").foregroundStyle(.secondary) } }
            .onAppear { if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                if let copied {
                    Label("Copied \(copied) \(copied == 1 ? "line" : "lines")", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .accessibilityIdentifier("log-copied")
                }
            }
            .animation(.easeOut(duration: 0.2), value: copied)
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Copy") {
                    UIPasteboard.general.string = log.text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    let n = log.entries.count
                    copied = n
                    Task { try? await Task.sleep(for: .seconds(2)); if copied == n { copied = nil } }
                }
                .disabled(log.entries.isEmpty)
                Button("Clear") { log.clear() }.disabled(log.entries.isEmpty)
            }
        }
    }
}
