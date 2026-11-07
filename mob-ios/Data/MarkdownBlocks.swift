import Foundation

/// The block structure of an agent reply: enough Markdown for chat (no tables, no HTML).
/// Inline styling (bold, code, links) is left to AttributedString.
enum MdBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String, text: String)
    case listItem(ordered: Bool, marker: String, depth: Int, text: String)
    case quote(String)
    case rule
}

private func match(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
    }
}

func parseMarkdown(_ src: String) -> [MdBlock] {
    var out: [MdBlock] = []
    let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var para: [String] = []
    func flush() {
        let text = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { out.append(.paragraph(text)) }
        para = []
    }
    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flush()
            let fence = String(trimmed.prefix(3))
            let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            i += 1
            while i < lines.count && !lines[i].drop(while: { $0 == " " }).hasPrefix(fence) { code.append(lines[i]); i += 1 }
            out.append(.code(lang: lang, text: code.joined(separator: "\n")))
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            flush()
        } else if match(#"^\s*([-*_])(\s*\1){2,}\s*$"#, line) != nil {
            flush()
            out.append(.rule)
        } else if let m = match(#"^(#{1,6})\s+(.*)$"#, String(trimmed)) {
            flush()
            out.append(.heading(level: m[1].count, text: m[2].trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
        } else if let m = match(#"^(\s*)[-*+]\s+(.*)$"#, line) {
            flush()
            out.append(.listItem(ordered: false, marker: "•", depth: m[1].count / 2, text: m[2]))
        } else if let m = match(#"^(\s*)(\d+)[.)]\s+(.*)$"#, line) {
            flush()
            out.append(.listItem(ordered: true, marker: m[2] + ".", depth: m[1].count / 2, text: m[3]))
        } else if trimmed.hasPrefix(">") {
            flush()
            var quote: [String] = []
            while i < lines.count, lines[i].drop(while: { $0 == " " }).hasPrefix(">") {
                quote.append(lines[i].drop(while: { $0 == " " }).dropFirst().trimmingCharacters(in: .whitespaces))
                i += 1
            }
            out.append(.quote(quote.joined(separator: "\n")))
            continue
        } else if para.isEmpty, line.hasPrefix("  "), case .listItem(let o, let mk, let d, let t)? = out.last {
            // A wrapped list item continues on an indented line.
            out[out.count - 1] = .listItem(ordered: o, marker: mk, depth: d, text: t + " " + trimmed)
        } else {
            para.append(line)
        }
        i += 1
    }
    flush()
    return out
}

/// The blocks in groups of about `size` characters, a long paragraph split after a sentence and a
/// long code block every `codeLines` lines, so a long message is several timeline rows. The lazy
/// timeline estimates rows it has not laid out, and a row far taller than that (a long reply) made
/// it alternate between the row laid out and estimated in every layout: the app hung.
func markdownChunks(_ blocks: [MdBlock], size: Int = 500, codeLines: Int = 20) -> [[MdBlock]] {
    var pieces: [MdBlock] = []
    for block in blocks {
        switch block {
        case .paragraph(let text) where text.count > size:
            pieces += sentences(text, size: size).map { .paragraph($0) }
        case .code(let lang, let text):
            let lines = text.components(separatedBy: "\n")
            pieces += stride(from: 0, to: max(lines.count, 1), by: codeLines).map {
                .code(lang: lang, text: lines[$0..<min($0 + codeLines, lines.count)].joined(separator: "\n"))
            }
        default:
            pieces.append(block)
        }
    }
    var chunks: [[MdBlock]] = []
    var current: [MdBlock] = [], weight = 0
    for piece in pieces {
        let w = piece.weight
        if !current.isEmpty, weight + w > size {
            chunks.append(current)
            current = []; weight = 0
        }
        current.append(piece); weight += w
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

/// About as tall as that many characters of body text: a code line is a short line of its own.
private extension MdBlock {
    var weight: Int {
        switch self {
        case .heading(_, let t), .paragraph(let t), .quote(let t): return max(t.count, 40)
        case .listItem(_, _, _, let t): return max(t.count, 40)
        case .code(_, let t): return 40 * (t.components(separatedBy: "\n").count + 1)
        case .rule: return 20
        }
    }
}

/// `text` cut after sentences into pieces of at most about `size` characters.
private func sentences(_ text: String, size: Int) -> [String] {
    var out: [String] = [], current = ""
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
        guard let s else { return }
        if !current.isEmpty, current.count + s.count > size {
            out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
        current += s
    }
    let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rest.isEmpty { out.append(rest) }
    return out.isEmpty ? [text] : out
}

/// `markdownChunks(parseMarkdown(text))`, kept by text: the timeline asks on every update.
@MainActor
enum MarkdownChunks {
    private final class Box { let chunks: [[MdBlock]]; init(_ c: [[MdBlock]]) { chunks = c } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 500
        return c
    }()

    static func of(_ text: String) -> [[MdBlock]] {
        if let hit = cache.object(forKey: text as NSString) { return hit.chunks }
        let chunks = markdownChunks(parseMarkdown(text))
        cache.setObject(Box(chunks), forKey: text as NSString)
        return chunks
    }
}
