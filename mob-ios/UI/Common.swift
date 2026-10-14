import SwiftUI
import UIKit

extension Color {
    static let success = Color(red: 0.09, green: 0.64, blue: 0.29)
    static let waiting = Color(red: 0.85, green: 0.47, blue: 0.02)
}

/// Renders an agent reply: blocks from parseMarkdown, inline styling from AttributedString.
struct MarkdownView: View {
    let text: String

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseMarkdown(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(inline(t)).font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                case .paragraph(let t):
                    Text(inline(t))
                case .listItem(_, let marker, let depth, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).frame(minWidth: 16, alignment: .leading)
                        Text(inline(t))
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                case .quote(let t):
                    HStack(spacing: 10) {
                        Rectangle().fill(.quaternary).frame(width: 3)
                        Text(inline(t)).foregroundStyle(.secondary)
                    }
                case .code(_, let t):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(t).font(.system(.footnote, design: .monospaced)).padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Decoded images by URL; artifacts never change.
@MainActor
enum ImageCache {
    static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 48 << 20
        return c
    }()
}

/// An image from mobd; tap opens it full screen.
struct RemoteImage: View {
    let client: APIClient
    let url: URL
    var fit = false
    @State private var image: UIImage?
    @State private var zoom = false

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .onTapGesture { if image != nil { zoom = true } }
        .task(id: url) {
            if let cached = ImageCache.cache.object(forKey: url as NSURL) { image = cached; return }
            if let loaded = try? await client.image(url) {
                ImageCache.cache.setObject(loaded, forKey: url as NSURL, cost: Int(loaded.size.width * loaded.size.height * 4))
                image = loaded
            }
        }
        .fullScreenCover(isPresented: $zoom) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().scaledToFit() }
            }
            .onTapGesture { zoom = false }
        }
    }
}

/// A coloured status pill for a turn.
struct StatusBadge: View {
    let task: AgentTask

    var body: some View {
        let (color, label): (Color, String) = {
            if task.waiting == true { return (.waiting, "Needs you") }
            switch task.status {
            case Status.queued: return (.gray, task.queuePosition.map { "Queued #\($0)" } ?? "Queued")
            case Status.running: return (.blue, "Running")
            case Status.succeeded: return (.success, "Succeeded")
            case Status.failed: return (.red, "Failed")
            case Status.cancelled: return (.orange, "Cancelled")
            default: return (.gray, task.status)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}
