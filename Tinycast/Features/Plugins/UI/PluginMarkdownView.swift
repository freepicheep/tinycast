import SwiftUI

/// A plugin's Markdown: headings, paragraphs, lists, quotes, code and rules, with inline styling.
struct PluginMarkdownView: View {
    @Environment(\.metrics) private var metrics
    let markdown: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case quote(String)
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(.system(size: level == 1 ? 20 : level == 2 ? 16 : 14, weight: .semibold))
                case .paragraph(let text):
                    Text(inline(text)).font(metrics.typography.rowTitle)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.sm) {
                        Text(verbatim: "•").foregroundStyle(.secondary)
                        Text(inline(text)).font(metrics.typography.rowTitle)
                    }
                case .quote(let text):
                    Text(inline(text))
                        .font(metrics.typography.rowTitle)
                        .foregroundStyle(.secondary)
                        .padding(.leading, metrics.spacing.sm)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.Colors.separator).frame(width: 2)
                        }
                case .code(let text):
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .padding(metrics.spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                                .fill(Theme.Colors.rowHover))
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Bold, italics, code and links; a string that isn't valid Markdown shows as typed.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let level = Self.headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
            } else if ["---", "***", "___"].contains(trimmed) {
                flush()
                blocks.append(.rule)
            } else if let rest = Self.dropPrefix(trimmed, ["- ", "* ", "+ "]) {
                flush()
                blocks.append(.bullet(rest))
            } else if let rest = Self.dropPrefix(trimmed, ["> "]) {
                flush()
                blocks.append(.quote(rest))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func dropPrefix(_ line: String, _ prefixes: [String]) -> String? {
        prefixes.first { line.hasPrefix($0) }.map { String(line.dropFirst($0.count)) }
    }
}
