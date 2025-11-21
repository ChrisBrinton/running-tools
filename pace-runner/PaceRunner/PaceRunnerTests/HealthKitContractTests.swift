import XCTest
import HealthKit

final class HealthKitContractTests: XCTestCase {

    func testWorkoutConfigurationCodingRoundTrip() throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        let data = try NSKeyedArchiver.archivedData(withRootObject: config, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: HKWorkoutConfiguration.self, from: data)
        )

        XCTAssertEqual(decoded.activityType, .running)
        XCTAssertEqual(decoded.locationType, .outdoor)
    }

    func testWorkoutSessionConfiguration() throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw XCTSkip("Health data unavailable on this device")
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        let store = HKHealthStore()
        let session = try HKWorkoutSession(healthStore: store, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        XCTAssertEqual(builder.workoutConfiguration.activityType, .running)
    }
}
