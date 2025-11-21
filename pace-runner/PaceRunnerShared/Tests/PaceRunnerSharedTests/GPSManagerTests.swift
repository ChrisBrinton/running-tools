import XCTest
import CoreLocation
import Combine
@testable import PaceRunnerShared

final class GPSManagerTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testPublishesValidLocationsAndDistance() {
        let mock = MockLocationManager()
        let manager = GPSManager(locationManager: mock)
        let expectation = expectation(description: "Location updates")
        expectation.expectedFulfillmentCount = 2

        manager.locationPublisher
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        manager.startTracking()

        let start = Date()
        mock.send(location: CLLocation(
            coordinate: .init(latitude: 37.3318, longitude: -122.0312),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: start
        ))

        mock.send(location: CLLocation(
            coordinate: .init(latitude: 37.3319, longitude: -122.0300),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: start.addingTimeInterval(2)
        ))

        waitForExpectations(timeout: 1)
        XCTAssertTrue(manager.totalDistance > 0)
        XCTAssertTrue(manager.isTracking)
    }

    func testResetClearsDistance() {
        let mock = MockLocationManager()
        let manager = GPSManager(locationManager: mock)
        manager.resetDistance()
        XCTAssertEqual(manager.totalDistance, 0)
    }
}

private final class MockLocationManager: LocationManagerProtocol {
    var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var activityType: CLActivityType = .other
    var distanceFilter: CLLocationDistance = 0
    var allowsBackgroundLocationUpdates: Bool = false

    private let backingManager = CLLocationManager()

    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}

    func send(location: CLLocation) {
        delegate?.locationManager?(backingManager, didUpdateLocations: [location])
    }
}
