import XCTest
import CoreLocation

final class CoreLocationContractTests: XCTestCase {

    func testDistanceComputation() {
        let cupertino = CLLocation(latitude: 37.332_331_41, longitude: -122.031_218_6)
        let applePark = CLLocation(latitude: 37.334_722, longitude: -122.008_889)

        let distance = cupertino.distance(from: applePark)
        XCTAssertGreaterThan(distance, 0)
        XCTAssertLessThan(distance, 3000) // within a few kilometers
    }

    func testCoordinateValidation() {
        var coordinate = CLLocationCoordinate2D(latitude: 91, longitude: 200)
        XCTAssertFalse(CLLocationCoordinate2DIsValid(coordinate))

        coordinate = CLLocationCoordinate2D(latitude: 37.3, longitude: -122.0)
        XCTAssertTrue(CLLocationCoordinate2DIsValid(coordinate))
    }
}
