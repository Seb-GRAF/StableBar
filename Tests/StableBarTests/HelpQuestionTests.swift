import Foundation
import Testing
@testable import StableBar

private let docs = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "docs")

/// The anchor GitHub gives a Markdown heading.
private func anchor(_ heading: Substring) -> String {
    heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
        .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        .replacingOccurrences(of: " ", with: "-")
}

@Test func helpShowsTheGuidesQuestionsPageUnchanged() throws {
    let page = try String(contentsOf: docs.appending(path: "questions.md"), encoding: .utf8)
    #expect(HelpQuestion.page == page, "Copy docs/questions.md into HelpQuestion.page unchanged.")
}

@Test func everyQuestionHasAnAnswerWhoseLinksReachTheGuide() throws {
    #expect(HelpQuestion.all.count >= 10)
    for question in HelpQuestion.all {
        #expect(question.question.hasSuffix("?"), "\(question.question)")
        #expect(!question.answer.isEmpty, "\(question.question)")
        for link in question.answer.matches(of: /\]\(([a-z-]+\.md)(?:#([a-z0-9-]+))?\)/) {
            let page = try String(contentsOf: docs.appending(path: String(link.1)), encoding: .utf8)
            if let target = link.2 {
                #expect(page.split(separator: "\n").filter { $0.hasPrefix("#") }.map(anchor).contains(String(target)),
                        "\(link.1)#\(target) in “\(question.question)”")
            }
        }
    }
}

@Test func feedbackFindsTheQuestionsItsTitleIsAbout() {
    #expect(HelpQuestion.answering("Windows go under the bar").map(\.question).contains("Why do windows go under the bar?"))
    #expect(HelpQuestion.answering("StableBar crashes after sleep").map(\.question)
        .contains("What do I do when StableBar crashes or something goes wrong?"))
    #expect(HelpQuestion.answering("Zebra quantum xylophone").isEmpty)
    #expect(HelpQuestion.answering("").isEmpty)
}
