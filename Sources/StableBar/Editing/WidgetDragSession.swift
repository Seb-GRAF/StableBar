import Foundation
import Observation

/// A payload belongs to one live drag in one list. Consume it before moving so
/// duplicate drop callbacks cannot produce another move or Undo step.
@MainActor @Observable
final class WidgetDragSession {
    struct Payload: Codable, Equatable {
        let widgetID: String
        let token: UUID
    }

    static let typeIdentifier = "com.stablebar.widget-move"
    private(set) var active: Payload?
    var insertion: String?

    func begin(_ widgetID: String) -> Payload {
        let payload = Payload(widgetID: widgetID, token: UUID())
        active = payload
        insertion = nil
        return payload
    }

    func accepts(_ payload: Payload) -> Bool { active == payload }

    func payload(from data: Data, source: WidgetDragSession?) -> Payload? {
        guard source === self, let payload = try? JSONDecoder().decode(Payload.self, from: data), accepts(payload) else { return nil }
        return payload
    }

    func drop(_ payload: Payload, move: (String) -> Void) -> Bool {
        guard accepts(payload) else { return false }
        end(payload)
        move(payload.widgetID)
        return true
    }

    func end(_ payload: Payload) {
        guard accepts(payload) else { return }
        active = nil
        insertion = nil
    }
}
