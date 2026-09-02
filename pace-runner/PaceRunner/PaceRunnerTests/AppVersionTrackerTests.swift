import XCTest
@testable import PaceRunnerShared

/// Tests for the install/update detection that triggers a launch sync.
///
/// The dirty-latch sync model suppresses a config push when the phone's
/// fingerprint already matches what it believes the watch holds. A fresh
/// install or an update leaves the counterpart empty while that latch still
/// looks clean, which is why configs were missing on first launch after an
/// update and appeared only a day later.
final class AppVersionTrackerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppVersionTrackerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstEverLaunchReportsFreshInstall() {
        let kind = AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")
        XCTAssertEqual(kind, .freshInstall)
    }

    func testRelaunchOnSameVersionReportsNothing() {
        AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")

        let kind = AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")
        XCTAssertNil(kind, "An ordinary relaunch must not trigger a resync")
    }

    func testBuildBumpReportsAnUpdate() {
        AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")

        let kind = AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (45)")
        XCTAssertEqual(kind, .updated(from: "1.2 (44)", to: "1.2 (45)"),
                       "A build-only bump is still a new install to the user")
    }

    func testMarketingVersionBumpReportsAnUpdate() {
        AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.1 (40)")

        let kind = AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")
        XCTAssertEqual(kind, .updated(from: "1.1 (40)", to: "1.2 (44)"))
    }

    /// Guards the once-per-launch contract: the caller syncs on a non-nil
    /// result, so a repeat call must not trigger a second sync.
    func testConsumingIsIdempotentWithinALaunch() {
        XCTAssertEqual(AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)"),
                       .freshInstall)
        XCTAssertNil(AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)"))
        XCTAssertNil(AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)"))
    }

    /// A downgrade (TestFlight rollback) also leaves the counterpart stale.
    func testDowngradeAlsoReportsAnUpdate() {
        AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")

        let kind = AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (43)")
        XCTAssertEqual(kind, .updated(from: "1.2 (44)", to: "1.2 (43)"))
    }

    func testResetRestoresFreshInstallBehavior() {
        AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)")
        AppVersionTracker.reset(defaults: defaults)

        XCTAssertEqual(AppVersionTracker.consumeLaunchKind(defaults: defaults, currentVersion: "1.2 (44)"),
                       .freshInstall)
    }
}
