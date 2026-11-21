/// Where setup puts the bar, and the change to the macOS menu bar that needs: the top edge hides the menu bar and below
/// it shows it, which takes Automation access to System Events first. While the menu bar can't hide, the bar waits
/// below it. The latest choice wins: an answer or a change that arrives for an earlier choice is dropped, and so is one
/// that arrives after Skip setup.
struct SetupPlacement: StateMachine, Equatable {
    typealias Placement = SetupPreferences.Placement

    enum Phase: Equatable {
        case unchosen
        /// Checking Automation access, which can mean macOS asks.
        case checkingAccess(Placement)
        /// Access is refused or not given yet; the choice applies once it's allowed in System Settings.
        case awaitingAccess(Placement)
        case changingMenuBar(Placement)
        case placed(Placement)
        /// The menu bar change failed, and setup shows why.
        case failed(Placement)
        /// Setup closed without saving: a choice waiting for access no longer applies.
        case skipped
    }

    enum Event: Equatable {
        case chose(Placement, menuBarHides: Bool)
        /// Automation access turned out allowed, as after the person allows it in System Settings.
        case accessAllowed(menuBarHides: Bool)
        case accessChecked(MenuBarAutoHide.Access, request: Int)
        /// `failure` is the error's message, or nil when the change worked.
        case menuBarChanged(failure: String?, request: Int)
        case skipped
    }

    /// `checkAccess` and `changeMenuBar` come last in what `handle` returns: their answer is the next event, and the
    /// owner handles it before any effect after them.
    enum Effect: Equatable {
        /// Moves the bar in setup's preview.
        case move(Placement)
        case checkAccess(request: Int)
        case changeMenuBar(hidden: Bool, request: Int)
        case showError(String?)
    }

    private(set) var phase = Phase.unchosen
    /// Counts choices, so an answer can tell whether it is for the latest one.
    private var request = 0

    /// A choice restored after StableBar moved itself counts as placed unless it was waiting for access: nothing it
    /// started is still running, and setup still checks the bar and the menu bar before it counts as taking effect.
    init(choice: Placement? = nil, awaitingAccess: Placement? = nil) {
        phase = awaitingAccess.map(Phase.awaitingAccess) ?? choice.map(Phase.placed) ?? .unchosen
    }

    var choice: Placement? {
        switch phase {
        case .unchosen, .skipped: nil
        case .checkingAccess(let placement), .awaitingAccess(let placement), .changingMenuBar(let placement),
             .placed(let placement), .failed(let placement): placement
        }
    }

    var awaitingAccess: Placement? {
        if case .awaitingAccess(let placement) = phase { placement } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .chose(let placement, let menuBarHides):
            return choose(placement, menuBarHides: menuBarHides)
        case .accessAllowed(let menuBarHides):
            guard case .awaitingAccess(let placement) = phase else { return [] }
            return choose(placement, menuBarHides: menuBarHides)
        case .accessChecked(let access, let answered):
            guard answered == request, case .checkingAccess(let placement) = phase else { return [] }
            guard access == .allowed else {
                phase = .awaitingAccess(placement)
                return fallback(from: placement) + [.showError(nil)]
            }
            phase = .changingMenuBar(placement)
            return [.changeMenuBar(hidden: placement == .top, request: request)]
        case .menuBarChanged(let failure, let answered):
            guard answered == request, case .changingMenuBar(let placement) = phase else { return [] }
            guard let failure else {
                phase = .placed(placement)
                return [.move(placement), .showError(nil)]
            }
            phase = .failed(placement)
            // -1743 is macOS refusing Automation access.
            let detail = failure.contains("-1743") ? MenuBarAutoHide.accessHint : failure
            return fallback(from: placement) + [.showError("StableBar couldn’t \(placement == .top ? "hide" : "show") the macOS menu bar. \(detail)")]
        case .skipped:
            phase = .skipped
            return []
        }
    }

    /// The top edge belongs to the menu bar while it shows, so the bar waits below it.
    private func fallback(from placement: Placement) -> [Effect] {
        placement == .top ? [.move(.belowMenuBar)] : []
    }

    private mutating func choose(_ placement: Placement, menuBarHides: Bool) -> [Effect] {
        request += 1
        // The bar leaves the top edge at once, but takes it only once the menu bar hides.
        let move: [Effect] = placement == .top ? [] : [.move(placement)]
        guard (placement == .top) != menuBarHides else {
            phase = .changingMenuBar(placement)
            return move + [.changeMenuBar(hidden: placement == .top, request: request)]
        }
        phase = .checkingAccess(placement)
        return move + [.checkAccess(request: request)]
    }
}
