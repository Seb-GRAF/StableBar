@testable import StableBar
import Testing

private let speakers = MixerState.Output(uid: "speakers", name: "MacBook Pro Speakers")
private let headphones = MixerState.Output(uid: "headphones", name: "AirPods Pro")
private let music = MixerState.Client(object: 10, bundleID: "com.apple.Music", name: "Music", playing: true)

/// A mixer with the speakers as the default output, both outputs connected and Music playing, allowed to tap.
private func mixer(settings: [String: MixerState.Setting] = [:], permission: MixerState.Permission = .allowed) -> MixerState {
    var mixer = MixerState(settings: settings)
    _ = mixer.handle(.outputsChanged([speakers, headphones], defaultOutput: "speakers"))
    _ = mixer.handle(.processesChanged([music], apps: ["com.apple.Music": "Music"]))
    _ = mixer.handle(.permissionChecked(permission))
    return mixer
}

@Test func helpersCountAsTheirAppAndOtherProcessesAsAppsOfTheirOwn() {
    let apps = MixerState.apps([
        .init(object: 1, bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper", playing: false),
        .init(object: 2, bundleID: "com.google.Chrome.helper.Renderer", name: "Google Chrome Helper (Renderer)", playing: true),
        .init(object: 3, bundleID: "afplay", name: "afplay", playing: true),
        .init(object: 4, bundleID: "com.apple.Music", name: "Music", playing: false),
    ], running: ["com.google.Chrome": "Google Chrome", "com.apple.Music": "Music", "com.google": "Not an app"])
    #expect(apps == [
        .init(id: "afplay", name: "afplay", processes: [3], playing: true, regular: false),
        .init(id: "com.google.Chrome", name: "Google Chrome", processes: [1, 2], playing: true, regular: true),
        .init(id: "com.apple.Music", name: "Music", processes: [4], playing: false, regular: true),
    ])
}

@Test func theFirstChangeAsksForTheRecordingPermissionAndTapsOnceAllowed() {
    var state = mixer(permission: .unknown)
    #expect(state.handle(.setVolume("com.apple.Music", 0.5))
            == [.save(["com.apple.Music": .init(volume: 0.5)]), .askPermission])
    #expect(state.permission == .asking)
    #expect(state.handle(.setMuted("com.apple.Music", true)) == [.save(["com.apple.Music": .init(volume: 0.5, muted: true)])])
    #expect(state.handle(.permissionChecked(.unknown)).isEmpty)
    #expect(state.permission == .asking)
    #expect(state.handle(.permissionAnswered(allowed: true))
            == [.startTap("com.apple.Music", .init(processes: [10], output: "speakers", gain: 0, playing: true))])
}

@Test func whileTheRecordingPermissionIsDeclinedNothingChanges() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)], permission: .unknown)
    #expect(state.handle(.permissionAnswered(allowed: false)).isEmpty)
    #expect(state.handle(.setVolume("com.apple.Music", 0.2)).isEmpty)
    #expect(state.setting("com.apple.Music").volume == 0.5)
    #expect(state.taps.isEmpty)
    #expect(state.handle(.permissionChecked(.allowed))
            == [.startTap("com.apple.Music", .init(processes: [10], output: "speakers", gain: 0.25, playing: true))])
}

@Test func loudnessFollowsTheSquareOfTheVolumeAndAChangeOnlySetsTheGain() {
    var state = mixer()
    #expect(state.handle(.setVolume("com.apple.Music", 0.5))
            == [.save(["com.apple.Music": .init(volume: 0.5)]),
                .startTap("com.apple.Music", .init(processes: [10], output: "speakers", gain: 0.25, playing: true))])
    #expect(state.handle(.setVolume("com.apple.Music", 0.8)) == [.save(["com.apple.Music": .init(volume: 0.8)]), .setGain("com.apple.Music", 0.8 * 0.8)])
    #expect(state.handle(.setMuted("com.apple.Music", true)).last == .setGain("com.apple.Music", 0))
}

@Test func theDefaultChoiceEndsTheTapAndForgetsTheApp() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)])
    #expect(state.taps["com.apple.Music"] != nil)
    #expect(state.handle(.setVolume("com.apple.Music", 1)) == [.save([:]), .stopTap("com.apple.Music")])
    #expect(state.settings.isEmpty)
}

@Test func anAppPlaysOnItsOwnOutputAndOnTheDefaultWhileThatOneIsAway() {
    var state = mixer()
    #expect(state.handle(.setOutput("com.apple.Music", "headphones")).last
            == .startTap("com.apple.Music", .init(processes: [10], output: "headphones", gain: 1, playing: true)))
    #expect(!state.fallsBack("com.apple.Music"))
    #expect(state.handle(.outputsChanged([speakers], defaultOutput: "speakers"))
            == [.stopTap("com.apple.Music"), .startTap("com.apple.Music", .init(processes: [10], output: "speakers", gain: 1, playing: true))])
    #expect(state.fallsBack("com.apple.Music"))
    #expect(state.handle(.outputsChanged([speakers, headphones], defaultOutput: "speakers"))
            == [.stopTap("com.apple.Music"), .startTap("com.apple.Music", .init(processes: [10], output: "headphones", gain: 1, playing: true))])
}

@Test func anAppFollowingTheDefaultMovesWithIt() {
    var state = mixer(settings: ["com.apple.Music": .init(muted: true)])
    #expect(state.handle(.outputsChanged([speakers, headphones], defaultOutput: "headphones"))
            == [.stopTap("com.apple.Music"), .startTap("com.apple.Music", .init(processes: [10], output: "headphones", gain: 0, playing: true))])
}

@Test func theTapFollowsTheAppsProcessesAndWhetherItPlays() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)])
    let paused = MixerState.Client(object: 10, bundleID: "com.apple.Music", name: "Music", playing: false)
    #expect(state.handle(.processesChanged([paused], apps: ["com.apple.Music": "Music"])) == [.setPlaying("com.apple.Music", false)])
    let helper = MixerState.Client(object: 11, bundleID: "com.apple.Music.helper", name: "Music Helper", playing: true)
    #expect(state.handle(.processesChanged([paused, helper], apps: ["com.apple.Music": "Music"]))
            == [.stopTap("com.apple.Music"), .startTap("com.apple.Music", .init(processes: [10, 11], output: "speakers", gain: 0.25, playing: true))])
    #expect(state.handle(.processesChanged([], apps: [:])) == [.stopTap("com.apple.Music")])
}

@Test func aTapThatFailedIsTriedAgainOnlyWhenItWouldDiffer() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)])
    #expect(state.handle(.tapFailed("com.apple.Music", state.taps["com.apple.Music"]!)) == [.stopTap("com.apple.Music")])
    #expect(state.handle(.processesChanged([music], apps: ["com.apple.Music": "Music"])).isEmpty)
    #expect(state.handle(.setOutput("com.apple.Music", "headphones")).last
            == .startTap("com.apple.Music", .init(processes: [10], output: "headphones", gain: 0.25, playing: true)))
}

@Test func theMixerListsRegularAppsAppsThatPlayAndAppsWithAChoiceOfTheirOwn() {
    let finder = MixerState.Client(object: 11, bundleID: "com.apple.finder", name: "Finder", playing: false)
    let agent = MixerState.Client(object: 12, bundleID: "com.apple.PowerChime", name: "PowerChime", playing: false)
    let slack = MixerState.Client(object: 13, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", playing: false)
    var state = MixerState(settings: ["com.tinyspeck.slackmacgap": .init(muted: true)])
    _ = state.handle(.processesChanged([music, finder, agent, slack], apps: ["com.apple.finder": "Finder"]))
    #expect(state.shown.map(\.id) == ["com.apple.finder", "com.apple.Music", "com.tinyspeck.slackmacgap"])
}

@Test func aFailureAfterAVolumeChangeStillEndsTheTap() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)])
    let started = state.taps["com.apple.Music"]!
    _ = state.handle(.setVolume("com.apple.Music", 0.8))
    #expect(state.handle(.tapFailed("com.apple.Music", started)) == [.stopTap("com.apple.Music")])
    #expect(state.taps["com.apple.Music"] == nil)
}

@Test func anOutputThatFailedIsTriedAgainOnceAFallbackWorked() {
    var state = mixer()
    _ = state.handle(.setOutput("com.apple.Music", "headphones"))
    #expect(state.handle(.tapFailed("com.apple.Music", state.taps["com.apple.Music"]!)) == [.stopTap("com.apple.Music")])
    #expect(state.handle(.outputsChanged([speakers], defaultOutput: "speakers")).last
            == .startTap("com.apple.Music", .init(processes: [10], output: "speakers", gain: 1, playing: true)))
    #expect(state.handle(.outputsChanged([speakers, headphones], defaultOutput: "speakers"))
            == [.stopTap("com.apple.Music"), .startTap("com.apple.Music", .init(processes: [10], output: "headphones", gain: 1, playing: true))])
}

@Test func theFailureOfAReplacedPlanLeavesTheNewOneRunning() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)])
    let replaced = state.taps["com.apple.Music"]!
    _ = state.handle(.setOutput("com.apple.Music", "headphones"))
    let current = state.taps["com.apple.Music"]
    #expect(state.handle(.tapFailed("com.apple.Music", replaced)).isEmpty)
    #expect(state.taps["com.apple.Music"] == current)
}

@Test func aFailureOfAStartSinceRepeatedStopsTheRepeatToo() {
    var state = mixer(settings: ["com.apple.Music": .init(volume: 0.5)])
    let first = state.taps["com.apple.Music"]!
    _ = state.handle(.setOutput("com.apple.Music", "headphones"))
    _ = state.handle(.setOutput("com.apple.Music", nil))
    #expect(state.taps["com.apple.Music"] == first)
    #expect(state.handle(.tapFailed("com.apple.Music", first)) == [.stopTap("com.apple.Music")])
    #expect(state.taps["com.apple.Music"] == nil)
}
