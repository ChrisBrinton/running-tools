import Foundation

/// Detects that the app is running for the first time after being installed or
/// updated, so launch code can force a sync.
///
/// The dirty-latch sync model suppresses a config push when the phone's
/// fingerprint already matches what it believes the watch has. A fresh install
/// or an app update leaves the counterpart with no configs while that
/// fingerprint still matches, so nothing is pushed and the watch sits empty
/// until some unrelated change happens to dirty the latch. Comparing the build
/// against the last one seen gives launch code a reliable "we just updated"
/// signal to sync on.
public enum AppVersionTracker {

    /// Why the current launch is considered new.
    public enum LaunchKind: Equatable {
        /// No previously recorded build — first launch after install (or after
        /// the app's defaults were cleared).
        case freshInstall
        /// The recorded build differs from the running one.
        case updated(from: String, to: String)
    }

    private static let storageKey = "lastLaunchedAppVersion"

    /// Marketing version and build of the running bundle, e.g. `"1.2 (44)"`.
    public static var currentVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Returns how this launch differs from the last recorded one, and records
    /// the current version so the next launch compares against it.
    ///
    /// Call once per launch: the recorded value is updated as a side effect, so
    /// a second call in the same session reports `nil`.
    /// - Parameters:
    ///   - defaults: Storage for the recorded version. Injectable for tests.
    ///   - currentVersion: The running version. Injectable for tests.
    /// - Returns: The launch kind, or `nil` when the version is unchanged.
    @discardableResult
    public static func consumeLaunchKind(
        defaults: UserDefaults = .standard,
        currentVersion: String = currentVersionString
    ) -> LaunchKind? {
        let previous = defaults.string(forKey: storageKey)
        defaults.set(currentVersion, forKey: storageKey)

        guard let previous = previous else { return .freshInstall }
        guard previous != currentVersion else { return nil }
        return .updated(from: previous, to: currentVersion)
    }

    /// Clears the recorded version. Test seam.
    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
