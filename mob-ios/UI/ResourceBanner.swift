import SwiftUI

/// The low-memory or low-disk banner (dismissible until the level changes).
struct ResourceBannerView: View {
    @Environment(AppState.self) private var app
    let banner: ResourceBanner
    @State private var closing: String?

    var body: some View {
        let desktops = app.desktops.sorted
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(banner.level == "critical" ? .red : .orange)
                    .font(.title3)
                Text(banner.text).font(.subheadline)
                Spacer()
                Button { app.desktops.dismissBanner() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }
            if !desktops.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(desktops) { d in
                        HStack {
                            Text(d.title ?? "Chat \(d.sessionId.prefix(8))")
                                .font(.caption).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: d.memoryBytes ?? 0, countStyle: .memory))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Close") { confirmClose(d.sessionId) }
                                .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .confirmationDialog(
            "Close desktop?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close desktop", role: .destructive) {
                if let id = closing { app.desktops.close(id) { if let e = $0 { app.chat.error = e } } }
            }
        } message: {
            Text("The running turn will be stopped and open windows closed. Files and browser logins are kept.")
        }
        .task(id: banner.dismissKey) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                app.desktops.refresh()
            }
        }
    }

    private func confirmClose(_ id: String) { closing = id }
}
