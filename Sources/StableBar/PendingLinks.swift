import Observation

@MainActor @Observable
final class PendingLinks {
    /// A `stablebar://add-source` link waiting for Settings › Packages to open its form.
    var source: PackageSourceLink?
    /// A `stablebar://package` link waiting for Settings › Packages to show its package.
    var package: PackageLink?
}
