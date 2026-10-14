import SwiftUI

/// Settings → Log: the in-memory debug log, newest at the bottom, with Copy and Clear.
struct LogView: View {
    private var log: Log { Log.shared }

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
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Copy") { UIPasteboard.general.string = log.text }.disabled(log.entries.isEmpty)
                Button("Clear") { log.clear() }.disabled(log.entries.isEmpty)
            }
        }
    }
}
