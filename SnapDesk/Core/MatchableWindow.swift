import Foundation

/// One live window as the claim loop sees it: identity, owner, and the title that matching runs
/// on. `pid` is what tells a window of a freshly launched instance from one of an instance that
/// was already running, which a restore with "move existing windows" off must leave alone.
struct MatchableWindow: Equatable, Hashable, Sendable {
    var id: String
    var pid: pid_t
    var bundleIdentifier: String
    var title: String
}
