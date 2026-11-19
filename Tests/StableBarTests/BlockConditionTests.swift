import Foundation
import Testing
@testable import StableBar

private func block(_ json: String) throws -> PopupBlock {
    try JSONDecoder().decode(PopupBlock.self, from: Data(json.utf8))
}

@Test func blockConditionsTakeOneConditionOrAList() throws {
    let one = try block(#"{"type":"text","text":"Live","showWhen":{"field":"phase","equals":"live"}}"#)
    #expect(one.showWhen?.count == 1)
    #expect(one.hideWhen == nil)
    let list = try block(#"{"type":"text","text":"Soon","hideWhen":[{"field":"phase","equals":"soon"},{"value":"remaining","below":0.2}]}"#)
    #expect(list.hideWhen?.count == 2)
    #expect(try block(#"{"type":"text","text":"Always","showWhen":null}"#).showWhen == nil)
}

@Test(arguments: [#"[]"#, #"{"field":"phase"}"#, #"[{"field":"phase","equals":"live","below":1}]"#,
                  #"{"field":"phase","equals":"live","state":"live"}"#, #""live""#])
func blockConditionsRejectAnEmptyListAndWhatRulesReject(conditions: String) {
    #expect(throws: DecodingError.self) { try block(#"{"type":"text","text":"Live","showWhen":\#(conditions)}"#) }
    #expect(throws: DecodingError.self) { try block(#"{"type":"text","text":"Live","hideWhen":\#(conditions)}"#) }
}

@Test func showWhenNeedsOneMatchingConditionAndHideWhenHidesOnAny() throws {
    let live = try block(#"{"type":"text","text":"Live","showWhen":{"field":"phase","equals":"live"}}"#)
    #expect(!live.isHidden(fields: ["phase": "live"], values: [:]))
    #expect(live.isHidden(fields: ["phase": "soon"], values: [:]))
    #expect(live.isHidden(fields: [:], values: [:]))

    let countdown = try block(#"{"type":"text","text":"in","showWhen":[{"field":"phase","equals":"soon"},{"field":"phase","equals":"now"}]}"#)
    #expect(!countdown.isHidden(fields: ["phase": "now"], values: [:]))
    #expect(!countdown.isHidden(fields: ["phase": "soon"], values: [:]))
    #expect(countdown.isHidden(fields: ["phase": "later"], values: [:]))

    let full = try block(#"{"type":"text","text":"Full","hideWhen":[{"field":"phase","equals":"none"},{"value":"remaining","above":1}]}"#)
    #expect(full.isHidden(fields: [:], values: ["remaining": 1]))
    #expect(full.isHidden(fields: ["phase": "none"], values: ["remaining": 0.4]))
    #expect(!full.isHidden(fields: ["phase": "live"], values: ["remaining": 0.4]))
    #expect(!full.isHidden(fields: [:], values: [:]))
}

@Test func hideWhenEmptyStillHidesABlockWhoseConditionsShowIt() throws {
    let title = try block(#"{"type":"field","field":"title","hideWhenEmpty":"title","showWhen":{"field":"phase","equals":"live"}}"#)
    #expect(title.isHidden(fields: ["phase": "live"], values: [:]))
    #expect(!title.isHidden(fields: ["phase": "live", "title": "Daily"], values: [:]))
}

@MainActor @Test func aWidgetWhoseConditionsHideEveryBlockLeavesTheBar() throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"meeting","type":"script","command":"true","position":"right",
                 "layout":{"type":"row","hideWhen":{"field":"phase","equals":"none"},"children":[{"type":"field","field":"text"}]}}]}
    """#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let script = ScriptWidget()
    store.widgetScripts.scripts["meeting"] = script
    script.output = ScriptOutput(text: "No meetings", fields: ["phase": "none"])
    store.barPresentation.updatePresentations()
    #expect(store.barPresentation.presentations["meeting"]?.hidden == true)
    script.output = ScriptOutput(text: "No calendar access", fields: ["access": "denied"])
    store.barPresentation.updatePresentations()
    #expect(store.barPresentation.presentations["meeting"]?.hidden == false)
}
