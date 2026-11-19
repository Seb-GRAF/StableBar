import SwiftUI

/// A block of Markdown as an answer from an AI shows it, each with inline Markdown.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    /// A list item, its marker a bullet or the item's number, indented by `depth`.
    case item(marker: String, text: String, depth: Int)
    case code(String)
    case table(header: [String], rows: [[String]])

    /// The blocks of `markdown`. A code fence that isn't closed yet, as while an answer arrives, runs to the end, and a
    /// table shows as text until its second line marks it as one.
    static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // The lines of a paragraph, or of a table when they start with a pipe.
        var paragraph: [Substring] = []
        var code: [Substring]?
        // The open code block's fence, which only a run of its character at least as long closes.
        var opener: Substring = ""
        func endParagraph() {
            if paragraph.count > 1, paragraph.allSatisfy(isRow), paragraph[1].wholeMatch(of: /[ |:-]*-[ |:-]*/) != nil {
                blocks.append(.table(header: cells(paragraph[0]), rows: paragraph.dropFirst(2).map(cells)))
            } else if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
            paragraph = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let fence = fence(line)
            if let lines = code {
                if let fence, fence.run.first == opener.first, fence.run.count >= opener.count, fence.rest.allSatisfy(\.isWhitespace) {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = lines + [line]
                }
            } else if let fence {
                endParagraph()
                opener = fence.run
                code = []
            } else if line.allSatisfy({ $0 == " " }) {
                endParagraph()
            } else if let heading = line.wholeMatch(of: /#{1,6} +(.+)/) {
                endParagraph()
                blocks.append(.heading(String(heading.1)))
            } else if let item = line.wholeMatch(of: /( *)(?:[-*+]|(\d+[.)])) +(.+)/) {
                endParagraph()
                blocks.append(.item(marker: item.2.map(String.init) ?? "•", text: String(item.3), depth: item.1.count / 2))
            } else {
                if let last = paragraph.last, isRow(last) != isRow(line) { endParagraph() }
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        endParagraph()
        return blocks
    }

    /// The run of three or more backticks or tildes that starts a code fence on `line`, and what follows it.
    private static func fence(_ line: Substring) -> (run: Substring, rest: Substring)? {
        let trimmed = line.drop { $0 == " " }
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        return run.count >= 3 ? (run, trimmed.dropFirst(run.count)) : nil
    }

    private static func isRow(_ line: Substring) -> Bool {
        line.drop { $0 == " " }.hasPrefix("|")
    }

    private static func cells(_ row: Substring) -> [String] {
        var row = row.trimmingCharacters(in: .whitespaces)[...]
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Markdown drawn block by block: paragraphs, headings, lists, code and tables.
struct MarkdownBlocks: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(text):
                    Self.inline(text)
                case let .heading(text):
                    Self.inline(text).fontWeight(.semibold)
                case let .item(marker, text, depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                        Self.inline(text)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                case let .code(text):
                    Text(text)
                        .monospaced()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                case let .table(header, rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            ForEach(header.indices, id: \.self) { Self.inline(header[$0]).fontWeight(.semibold) }
                        }
                        ForEach(rows.indices, id: \.self) { row in
                            Rectangle().fill(.foreground.opacity(0.12)).frame(height: 1)
                            GridRow {
                                ForEach(rows[row].indices, id: \.self) { Self.inline(rows[row][$0]) }
                            }
                        }
                    }
                }
            }
        }
    }

    static func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}
