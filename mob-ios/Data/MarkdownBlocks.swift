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
