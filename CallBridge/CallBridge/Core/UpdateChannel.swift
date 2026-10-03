import Foundation

// MARK: - Update Channel

/// Which manifest the updater follows. Stable reads callbridge-update.json on main,
/// beta reads the copy on the beta branch. Stored per user in UserDefaults.
enum UpdateChannel: String {
    case stable
    case beta

    static let defaultsKey = "updateChannel"

    static var current: UpdateChannel {
        // No stored choice yet: follow the build itself, so a manually installed beta
        // is not immediately offered a downgrade to stable.
        get {
            UpdateChannel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
                ?? UpdateChannel(rawValue: appBuildChannel) ?? .stable
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var branch: String { self == .stable ? "main" : "beta" }

    var manifestURL: String {
        "https://raw.githubusercontent.com/23492/callbridge/\(branch)/callbridge-update.json"
    }
}

/// Semver subset used for releases: MAJOR.MINOR.PATCH with an optional "-beta.N".
/// A beta sorts below its final release (2.1.0-beta.3 < 2.1.0).
struct AppVersion: Comparable, Equatable {
    let core: [Int]
    let beta: Int?

    init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let nums = first.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard nums.count == 3, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        core = nums.map { $0! }
        if parts.count == 2 {
            let pre = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard pre.count == 2, pre[0] == "beta", let n = Int(pre[1]), n >= 0 else { return nil }
            beta = n
        } else {
            beta = nil
        }
    }

    var isBeta: Bool { beta != nil }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        switch (lhs.beta, rhs.beta) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        default: return false
        }
    }
}

/// What the updater should offer, given the installed build and the manifests it fetched.
/// Pure function so the channel rules are testable without networking or Cocoa.
enum UpdateDecision: Equatable {
    case none
    case upgrade(String)
    /// Leaving the beta channel: go back to the stable build, even if it is older.
    case returnToStable(String)
}

func decideUpdate(installed: String, buildChannel: String, selected: UpdateChannel,
                  stableManifest: String?, betaManifest: String?) -> UpdateDecision {
    guard let local = AppVersion(installed) else { return .none }
    // Stable never follows a beta version, even if one leaks into main's manifest.
    let stable = stableManifest.flatMap(AppVersion.init).flatMap { $0.isBeta ? nil : $0 }
    let beta = betaManifest.flatMap(AppVersion.init)

    switch selected {
    case .stable:
        guard let remote = stable else { return .none }
        if remote > local { return .upgrade(stableManifest!) }
        if buildChannel == UpdateChannel.beta.rawValue && remote != local {
            return .returnToStable(stableManifest!)
        }
        return .none
    case .beta:
        // Beta testers also get a stable release once it overtakes the newest beta.
        let candidates = [(beta, betaManifest), (stable, stableManifest)]
            .compactMap { v, s -> (AppVersion, String)? in v.map { ($0, s!) } }
        guard let best = candidates.max(by: { $0.0 < $1.0 }), best.0 > local else { return .none }
        return .upgrade(best.1)
    }
}
