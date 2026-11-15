import AppKit
import Testing
@testable import StableBar

@MainActor struct JSONTextViewTests {
    @Test func substitutionsLeaveTypedTextAsIs() throws {
        let (window, _, textView) = try hostedTextView("\"a\": \"b\" -- x")
        defer { window.close() }
        // Applies every substitution that is on, as typing would after a pause.
        textView.checkTextInDocument(nil)
        #expect(textView.string == "\"a\": \"b\" -- x")
        #expect(!textView.isContinuousSpellCheckingEnabled && !textView.isGrammarCheckingEnabled)
        #expect(!textView.isRichText && textView.allowsUndo && textView.usesFindBar)
    }

    @Test func commandZUndoesAndShiftCommandZRedoesTyping() throws {
        let (window, _, textView) = try hostedTextView("{}")
        defer { window.close() }
        textView.insertText("x", replacementRange: textView.selectedRange())
        #expect(textView.string == "{}x")
        #expect(window.performKeyEquivalent(with: try key("z", code: 6, .command, in: window)))
        #expect(textView.string == "{}")
        #expect(window.performKeyEquivalent(with: try key("z", code: 6, [.command, .shift], in: window)))
        #expect(textView.string == "{}x")
    }

    @Test func commandZWithNothingToUndoIsSwallowed() throws {
        let (window, _, textView) = try hostedTextView("{}")
        defer { window.close() }
        #expect(window.performKeyEquivalent(with: try key("z", code: 6, .command, in: window)))
        #expect(textView.string == "{}")
    }

    @Test func commandZIsLeftAloneWithoutFocus() throws {
        let (window, _, textView) = try hostedTextView("{}")
        defer { window.close() }
        window.makeFirstResponder(nil)
        #expect(!textView.performKeyEquivalent(with: try key("z", code: 6, .command, in: window)))
    }

    @Test(arguments: [("{\n  \"a\": {", "{\n  \"a\": {\n    "), ("[", "[\n  "), ("  \"b\": 1", "  \"b\": 1\n  "),
                      ("  \"c\": [  ", "  \"c\": [  \n    ")])
    func returnKeepsIndentationAndIndentsAfterAnOpeningBracket(text: String, expected: String) throws {
        let (window, _, textView) = try hostedTextView(text)
        defer { window.close() }
        textView.insertNewline(nil)
        #expect(textView.string == expected)
        #expect(window.performKeyEquivalent(with: try key("z", code: 6, .command, in: window)))
        #expect(textView.string == text)
    }

    @Test func tabInsertsTwoSpaces() throws {
        let (window, _, textView) = try hostedTextView("")
        defer { window.close() }
        textView.insertTab(nil)
        #expect(textView.string == "  ")
    }

    @Test func commandFShowsTheFindBar() async throws {
        let (window, scrollView, _) = try hostedTextView("{\"a\": 1}")
        defer { window.close() }
        #expect(window.performKeyEquivalent(with: try key("f", code: 3, .command, in: window)))
        #expect(await poll { scrollView.isFindBarVisible })
    }

    @Test func escapeClosesAnOpenFindBar() async throws {
        let (window, scrollView, textView) = try hostedTextView("{\"a\": 1}")
        defer { window.close() }
        #expect(window.performKeyEquivalent(with: try key("f", code: 3, .command, in: window)))
        try #require(await poll { scrollView.isFindBarVisible })
        #expect(window.performKeyEquivalent(with: try key("\u{1b}", code: 53, in: window)))
        #expect(await poll { !scrollView.isFindBarVisible })
        #expect(!textView.performKeyEquivalent(with: try key("\u{1b}", code: 53, in: window)))
    }

    @Test func selectLineSelectsTheWholeLine() throws {
        let (window, _, textView) = try hostedTextView("{\n  \"a\": 1\n}")
        defer { window.close() }
        window.makeFirstResponder(nil)
        textView.selectLine(2)
        #expect(textView.selectedRange() == NSRange(location: 2, length: 9))
        #expect(window.firstResponder === textView)
        textView.selectLine(9)
        #expect(textView.selectedRange() == NSRange(location: 2, length: 9))
    }
}

struct JSONSyntaxProblemTests {
    @Test func curlyQuoteNamesItsLineAndCharacter() throws {
        let text = "{\n  \"label\": “hi”\n}"
        let problem = try #require(jsonSyntaxProblem(decodingError(text), in: text))
        #expect(problem.line == 2)
        #expect(problem.message.hasPrefix("Line 2: ") && problem.message.contains("“"))
        #expect(!problem.message.contains("â") && !problem.message.contains("column"))
    }

    @Test func multiByteTextBeforeTheErrorKeepsTheLineRight() throws {
        let text = "{\n  \"é\": 1,\n  \"ü\": 2,\n  x: 3\n}"
        let problem = try #require(jsonSyntaxProblem(decodingError(text), in: text))
        #expect(problem.line == 4)
        #expect(problem.message.hasPrefix("Line 4: ") && problem.message.contains("'x'"))
    }

    @Test func errorsWithoutAPositionAreLeftToErrorMessage() {
        #expect(jsonSyntaxProblem(decodingError("{\"a\": 1"), in: "{\"a\": 1") == nil)
        #expect(jsonSyntaxProblem(decodingError("[1]"), in: "[1]") == nil)
        #expect(jsonSyntaxProblem(CocoaError(.fileReadUnknown), in: "{}") == nil)
    }

    private func decodingError(_ text: String) -> Error {
        do {
            _ = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(text.utf8))
            return CocoaError(.featureUnsupported)
        } catch { return error }
    }
}

@MainActor private func hostedTextView(_ text: String) throws -> (NSWindow, NSScrollView, JSONTextView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let scrollView = JSONTextView.makeScrollView()
    window.contentView = scrollView
    let textView = try #require(scrollView.documentView as? JSONTextView)
    textView.string = text
    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    window.orderFrontRegardless()
    window.makeFirstResponder(textView)
    return (window, scrollView, textView)
}

@MainActor private func key(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                    in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}

@MainActor private func poll(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
    }
    return false
}
