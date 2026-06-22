import Foundation

/// Build-baked configuration for the home-server publisher.
///
/// Users don't see or type the server URL — it's baked into the Info.plist
/// (`PaceRunnerServerURL`). This avoids fat-finger errors and keeps
/// onboarding to "install app → register → done." Override in custom
/// debug builds by editing the plist value or supplying a different
/// Info.plist via build settings.
enum PublisherConfig {
    /// The home server's base URL. Reads from Info.plist; falls back to
    /// production if the key is missing for some reason (shouldn't happen
    /// in a real build).
    static var serverBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PaceRunnerServerURL") as? String
            ?? "https://pacerunner.brintontech.com"
        return URL(string: raw) ?? URL(string: "https://pacerunner.brintontech.com")!
    }
}
