import Foundation

@MainActor
final class NativeWidgetEvents {
    private var observers: [UUID: (widgetID: String, receive: (String, [String: String]) -> Void)] = [:]

    func register(widgetID: String, receive: @escaping (String, [String: String]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = (widgetID, receive)
        return id
    }

    func unregister(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func send(_ event: String, environment: [String: String], to widgetIDs: Set<String>) {
        for observer in observers.values where widgetIDs.contains(observer.widgetID) {
            observer.receive(event, environment)
        }
    }
}
