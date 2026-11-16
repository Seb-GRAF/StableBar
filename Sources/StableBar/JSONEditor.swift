import AppKit
import SwiftUI

/// Plain-text JSON editing: no smart substitutions, two-space indentation, and its own undo and find keys,
/// because the hidden Edit menu leaves ⌘Z to the Undo button in the Settings footer.
@MainActor final class JSONTextView: NSTextView {
    static func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = JSONTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.configureForJSON()
        scrollView.documentView = textView
        return scrollView
    }

    private func configureForJSON() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textColor = .textColor
        textContainerInset = NSSize(width: 4, height: 6)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The finder's highlight updates on a timer that can fire after the editor is freed, so shut the finder down
        // while the editor still exists.
        if newWindow == nil, enclosingScrollView?.isFindBarVisible == true { performFinderAction(.hideFindInterface) }
        usesFindBar = newWindow != nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers.isEmpty, enclosingScrollView?.isFindBarVisible == true {
            performFinderAction(.hideFindInterface)
            return true
        }
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let letters = [event.characters, event.charactersIgnoringModifiers].compactMap { $0?.lowercased() }
        // A non-Latin layout types its own letter, so the key's place stands in; a Latin layout may type another
        // letter there, such as Y on QWERTZ.
        let byPlace = letters.contains { $0.contains { $0.isASCII && $0.isLetter } }
            ? nil : ([6: "z", 3: "f", 5: "g"] as [UInt16: String])[event.keyCode]
        switch (letters.first { ["z", "f", "g"].contains($0) } ?? byPlace, modifiers) {
        // TextKit 2 posts no text change for undo and redo, so say so, or the sheet would apply the old text.
        case ("z", [.command]):
            if undoManager?.canUndo == true {
                undoManager?.undo()
                didChangeText()
            }
        case ("z", [.command, .shift]):
            if undoManager?.canRedo == true {
                undoManager?.redo()
                didChangeText()
            }
        case ("f", [.command]): performFinderAction(.showFindInterface)
        case ("g", [.command]): performFinderAction(.nextMatch)
        case ("g", [.command, .shift]): performFinderAction(.previousMatch)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let cursor = selectedRange().location
        let line = text.lineRange(for: NSRange(location: cursor, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: cursor - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let opensBlock = before.trimmingCharacters(in: .whitespaces).last.map { $0 == "{" || $0 == "[" } ?? false
        insertText("\n" + indent + (opensBlock ? "  " : ""), replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    /// Selects line `line` (1-based) and focuses the editor; a line past the end leaves the selection alone.
    func selectLine(_ line: Int) {
        guard line >= 1 else { return }
        let text = string as NSString
        var range = text.lineRange(for: NSRange(location: 0, length: 0))
        for _ in 1..<line {
            let next = NSMaxRange(range)
            guard next < text.length else { return }
            range = text.lineRange(for: NSRange(location: next, length: 0))
        }
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    private func performFinderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}

/// Lets a sheet point the editor at a line, such as where a syntax error is, and see whether its find bar is open.
@MainActor @Observable final class JSONEditorController {
    @ObservationIgnored weak var textView: JSONTextView?
    var isFindBarVisible = false

    func selectLine(_ line: Int) { textView?.selectLine(line) }
}

struct JSONEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: JSONEditorController

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = JSONTextView.makeScrollView()
        if let textView = scrollView.documentView as? JSONTextView {
            textView.string = text
            textView.delegate = context.coordinator
            controller.textView = textView
        }
        context.coordinator.findBar = scrollView.observe(\.isFindBarVisible) { [controller] scrollView, _ in
            MainActor.assumeIsolated { controller.isFindBarVisible = scrollView.isFindBarVisible }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        // Setting the string clears undo, so only an outside change replaces it.
        guard let textView = scrollView.documentView as? JSONTextView, textView.string != text else { return }
        textView.string = text
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var findBar: NSKeyValueObservation?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

struct JSONSyntaxProblem: Equatable {
    let line: Int
    let message: String
}

/// The first JSON syntax error in `text` and a message naming its line, or nil for valid JSON. The decoder words
/// its errors best, but checks strings only once a value is decoded, which `ConfigurationValue` turns into a type
/// error; `JSONSerialization` checks them as it reads, so the earlier line of the two wins.
func jsonSyntaxProblem(in text: String) -> JSONSyntaxProblem? {
    let data = Data(text.utf8)
    var errors: [NSError] = []
    do {
        _ = try JSONDecoder().decode(ConfigurationValue.self, from: data)
    } catch let DecodingError.dataCorrupted(context) {
        if let underlying = context.underlyingError as NSError? { errors.append(underlying) }
    } catch {}
    do {
        _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    } catch {
        errors.append(error as NSError)
    }
    return errors.compactMap { jsonSyntaxProblem($0, in: text) }.min { $0.line < $1.line }
}

/// Both parsers count UTF-8 bytes, may point one byte past the culprit and print that byte as Latin-1, so the real
/// character is read back from the text.
private func jsonSyntaxProblem(_ error: NSError, in text: String) -> JSONSyntaxProblem? {
    guard let detail = error.userInfo[NSDebugDescriptionErrorKey] as? String else { return nil }
    let bytes = Array(text.utf8)
    let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int
    let line: Int
    if let index {
        line = 1 + bytes.prefix(min(max(index, 0), bytes.count)).count { $0 == UInt8(ascii: "\n") }
    } else if let match = detail.firstMatch(of: /line (\d+)/), let number = Int(match.1) {
        line = number
    } else {
        return nil
    }
    var message = detail.replacing(#/ around line \d+, column \d+/#, with: "")
        .replacing(#/ around character \d+/#, with: "")
    if let index, let match = message.firstMatch(of: /Unexpected character '(.)'/),
       let scalar = match.1.unicodeScalars.first, match.1.unicodeScalars.count == 1, scalar.value <= 0xFF {
        for offset in [index, index - 1] where bytes.indices.contains(offset) && bytes[offset] == UInt8(scalar.value) {
            guard let start = text.utf8.index(text.utf8.startIndex, offsetBy: offset).samePosition(in: text)
            else { continue }
            message.replaceSubrange(match.1.startIndex..<match.1.endIndex, with: String(text[start]))
            break
        }
    }
    return JSONSyntaxProblem(line: line, message: "Line \(line): \(message)")
}
