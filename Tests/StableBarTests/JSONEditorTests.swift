import AppKit
import SwiftUI
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

    @Test func commandZFollowsTheKeyOnANonLatinLayoutButNotOnQWERTZ() throws {
        let (window, _, textView) = try hostedTextView("{}")
        defer { window.close() }
        textView.insertText("x", replacementRange: textView.selectedRange())
        // On QWERTZ, the key where QWERTY has Z types Y.
        #expect(!textView.performKeyEquivalent(with: try key("y", code: 6, .command, in: window)))
        #expect(textView.string == "{}x")
        #expect(window.performKeyEquivalent(with: try key("я", code: 6, .command, in: window)))
        #expect(textView.string == "{}")
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
        let problem = try #require(jsonSyntaxProblem(in: "{\n  \"label\": “hi”\n}"))
        #expect(problem.line == 2)
        #expect(problem.message.hasPrefix("Line 2: ") && problem.message.contains("“"))
        #expect(!problem.message.contains("â") && !problem.message.contains("column"))
    }

    @Test func multiByteTextBeforeTheErrorKeepsTheLineRight() throws {
        let problem = try #require(jsonSyntaxProblem(in: "{\n  \"é\": 1,\n  \"ü\": 2,\n  x: 3\n}"))
        #expect(problem.line == 4)
        #expect(problem.message.hasPrefix("Line 4: ") && problem.message.contains("'x'"))
    }

    @Test(arguments: [("{\"a\": \"x,\n  \"b\": 2\n}", 1), ("{\"a\": \"C:\\path\"}", 1), ("{\n  \"a\": \"\tb\"\n}", 2),
                      ("{\n  \"a\": 1", 2)])
    func mistakesTheDecoderMissesNameTheirLine(text: String, line: Int) throws {
        let problem = try #require(jsonSyntaxProblem(in: text))
        #expect(problem.line == line)
        #expect(problem.message.hasPrefix("Line \(line): ") && !problem.message.contains("column"))
    }

    @Test func validJSONHasNoSyntaxProblem() {
        #expect(jsonSyntaxProblem(in: "{}") == nil)
        #expect(jsonSyntaxProblem(in: "[1]") == nil)
        #expect(jsonSyntaxProblem(in: "{\"a\": {\"b\": [1, true, null]}}") == nil)
    }
}

@MainActor struct JSONSheetTests {
    @Test func returnInTheSheetInsertsANewlineInsteadOfApplying() async throws {
        let probe = SheetProbe()
        let (window, textView) = try await hostedSheet("{", probe: probe)
        defer { window.close() }
        press(try key("\r", code: 36, in: window), in: window)
        #expect(textView.string == "{\n  ")
        #expect(probe.applied.isEmpty && probe.closed == 0)
    }

    @Test func escapeClosesTheFindBarBeforeTheSheet() async throws {
        let probe = SheetProbe()
        let (window, textView) = try await hostedSheet("{\"a\": 1}", probe: probe)
        defer { window.close() }
        let scrollView = try #require(textView.enclosingScrollView)
        press(try key("f", code: 3, .command, in: window), in: window)
        try #require(await poll { scrollView.isFindBarVisible })
        press(try key("\u{1b}", code: 53, in: window), in: window)
        #expect(await poll { !scrollView.isFindBarVisible })
        #expect(probe.closed == 0)
        press(try key("\u{1b}", code: 53, in: window), in: window)
        #expect(await poll { probe.closed == 1 })
    }

    @Test func escapeInTheTextWithTheFindBarOpenClosesOnlyTheFindBar() async throws {
        let probe = SheetProbe()
        let (window, textView) = try await hostedSheet("{\"a\": 1}", probe: probe)
        defer { window.close() }
        let scrollView = try #require(textView.enclosingScrollView)
        press(try key("f", code: 3, .command, in: window), in: window)
        try #require(await poll { scrollView.isFindBarVisible })
        window.makeFirstResponder(textView)
        // Let SwiftUI redraw Cancel without its Escape shortcut, as it does long before a person presses Escape.
        let host = try #require(window.contentView)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        press(try key("\u{1b}", code: 53, in: window), in: window)
        #expect(await poll { !scrollView.isFindBarVisible })
        #expect(probe.closed == 0)
    }

    @Test func returnInTheFindBarFindsInsteadOfApplying() async throws {
        let probe = SheetProbe()
        let (window, textView) = try await hostedSheet("{\"a\": 1}", probe: probe)
        defer { window.close() }
        let scrollView = try #require(textView.enclosingScrollView)
        press(try key("f", code: 3, .command, in: window), in: window)
        try #require(await poll { scrollView.isFindBarVisible })
        press(try key("\r", code: 36, in: window), in: window)
        for _ in 0..<20 { await Task.yield() }
        #expect(probe.applied.isEmpty && probe.closed == 0)
        #expect(scrollView.isFindBarVisible)
    }

    @Test func applyAfterUndoAndRedoAppliesWhatTheEditorShows() async throws {
        let probe = SheetProbe()
        let (window, textView) = try await hostedSheet("{}", probe: probe)
        defer { window.close() }
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText("\"a\": 1", replacementRange: textView.selectedRange())
        press(try key("z", code: 6, .command, in: window), in: window)
        #expect(textView.string == "{}")
        window.makeFirstResponder(nil)
        press(try key("\r", code: 36, in: window), in: window)
        #expect(await poll { probe.applied.count == 1 })
        #expect(probe.applied == [[:]])

        window.makeFirstResponder(textView)
        press(try key("z", code: 6, [.command, .shift], in: window), in: window)
        #expect(textView.string == "{\"a\": 1}")
        window.makeFirstResponder(nil)
        press(try key("\r", code: 36, in: window), in: window)
        #expect(await poll { probe.applied.count == 2 })
        #expect(probe.applied.last == ["a": .number(1)])
    }

    @Test func applyingCurlyQuotesSelectsTheErrorLine() async throws {
        let probe = SheetProbe()
        let (window, textView) = try await hostedSheet("{\n  \"label\": “hi”\n}", probe: probe)
        defer { window.close() }
        window.makeFirstResponder(nil)
        press(try key("\r", code: 36, in: window), in: window)
        #expect(await poll {
            window.firstResponder === textView && textView.selectedRange() == NSRange(location: 2, length: 16)
        })
        #expect(probe.applied.isEmpty && probe.closed == 0)
    }

    @Test func applyingValidJSONHandsOverTheValuesAndCloses() async throws {
        let probe = SheetProbe()
        let (window, _) = try await hostedSheet("{\"label\": \"hi\"}", probe: probe)
        defer { window.close() }
        window.makeFirstResponder(nil)
        press(try key("\r", code: 36, in: window), in: window)
        #expect(await poll { probe.closed == 1 })
        #expect(probe.applied == [["label": .string("hi")]])

        let refused = SheetProbe()
        refused.result = "Nope"
        let (otherWindow, _) = try await hostedSheet("{\"label\": \"hi\"}", probe: refused)
        defer { otherWindow.close() }
        otherWindow.makeFirstResponder(nil)
        press(try key("\r", code: 36, in: otherWindow), in: otherWindow)
        #expect(await poll { refused.applied.count == 1 })
        #expect(refused.closed == 0)
    }

    private func hostedSheet(_ text: String, probe: SheetProbe) async throws -> (NSWindow, JSONTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let host = NSHostingView(rootView: JSONSheet(title: "Clock as JSON", text: text,
                                                     apply: { probe.applied.append($0); return probe.result },
                                                     close: { probe.closed += 1 }))
        window.contentView = host
        window.orderFrontRegardless()
        var found: JSONTextView?
        let appeared = await poll {
            host.layoutSubtreeIfNeeded()
            found = jsonTextView(in: host)
            return found != nil
        }
        let textView = try #require(appeared ? found : nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        return (window, textView)
    }

    /// Sends a key as AppKit does: command keys try key equivalents first, other keys reach the focused view first.
    private func press(_ event: NSEvent, in window: NSWindow) {
        if event.modifierFlags.contains(.command), window.performKeyEquivalent(with: event) { return }
        window.sendEvent(event)
    }

    private func jsonTextView(in view: NSView) -> JSONTextView? {
        view as? JSONTextView ?? view.subviews.lazy.compactMap { jsonTextView(in: $0) }.first
    }
}

@MainActor private final class SheetProbe {
    var applied: [[String: ConfigurationValue]] = []
    var closed = 0
    var result: String?
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
