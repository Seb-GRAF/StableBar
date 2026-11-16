import Observation

@MainActor @Observable
final class PendingLinks {
    /// A `stablebar://theme` link waiting to be tried or installed in Settings › Theme.
    var theme: ThemeLinkCandidate?
    /// Why the last `stablebar://theme` link could not be opened in Settings › Theme.
    var themeError: String?
    /// A `stablebar://add-source` link waiting for Settings › Store to open its form.
    var source: PackageSourceLink?
    /// A `stablebar://package` link waiting for Settings › Store to show its package.
    var package: PackageLink?
}
