# CoreLocation Integration Contract

**Framework**: CoreLocation
**Platform**: watchOS 10.0+
**Purpose**: GPS tracking for distance and pace calculation

## Contract Tests Required

Contract tests verify correct integration with CoreLocation APIs, handling of location updates, errors, and permission states.

---

## 1. Location Manager Setup

### Test: Configure Location Manager for Running
**Given**: Fresh CLLocationManager instance
**When**: GPSManager configures for workout
**Then**:
- `desiredAccuracy` = `kCLLocationAccuracyBest`
- `activityType` = `.fitness`
- `distanceFilter` = 5.0 meters
- `allowsBackgroundLocationUpdates` = true (watchOS)
- Configuration completes without errors

**Constitution**: Aligns with battery optimization (distanceFilter reduces updates)

---

### Test: Request Location Permissions
**Given**: App never requested location access
**When**: GPSManager calls `requestAlwaysAuthorization()` (watchOS)
**Then**:
- Permission dialog presented
- After grant: `authorizationStatus` = `.authorizedAlways`
- After denial: `authorizationStatus` = `.denied`

---

## 2. Location Updates

### Test: Start Location Updates
**Given**: Location permission granted
**When**: GPSManager calls `startUpdatingLocation()`
**Then**:
- Delegate receives `locationManager(_:didUpdateLocations:)` callback
- Locations arrive at ~1 Hz rate
- Each CLLocation has valid timestamp, coordinate, horizontalAccuracy
- Return success

---

### Test: Stop Location Updates
**Given**: Active location updates
**When**: GPSManager calls `stopUpdatingLocation()`
**Then**:
- Delegate stops receiving location callbacks
- GPS hardware powers down (battery saving)
- Return success

---

### Test: Location Quality Filtering
**Given**: Stream of location updates with varying accuracy
**When**: Locations arrive with `horizontalAccuracy` 10m, 65m, 30m
**Then**:
- Accept locations with accuracy <50m
- Reject locations with accuracy ≥50m
- Reject locations with negative accuracy (invalid)
- Reject locations older than 10 seconds
- Only valid locations passed to PaceCalculator

---

## 3. Distance Calculation

### Test: Calculate Distance Between Locations
**Given**: Two CLLocation objects 100m apart
**When**: Call `location1.distance(from: location2)`
**Then**:
- Returns distance in meters (±1m accuracy)
- Uses WGS-84 ellipsoid calculation
- Computation completes in <1ms
- Return ~100.0

---

### Test: Accumulate Total Distance
**Given**: Stream of locations over 1 mile
**When**: GPSManager processes each location update
**Then**:
- Total distance accumulates correctly
- Final distance within ±2% of actual (1609m ±32m)
- Distance never decreases (monotonic)

---

## 4. Error Handling

### Test: Permission Denied Error
**Given**: User denies location access
**When**: Attempt to start location updates
**Then**:
- Delegate receives `locationManager(_:didFailWithError:)` with `.denied`
- UI displays permission required message
- Workout start disabled until permission granted

---

### Test: Location Unknown Error
**Given**: GPS signal temporarily unavailable (tunnel, building)
**When**: Location manager cannot determine position
**Then**:
- Delegate receives error code `.locationUnknown`
- GPSManager continues using last known location
- UI displays "GPS signal lost" warning
- Pace calculator uses last valid pace
- Error clears when signal restored

---

### Test: Accuracy Degradation
**Given**: Active location updates with good accuracy
**When**: Accuracy degrades to >50m (urban canyon, trees)
**Then**:
- GPSManager filters out poor-quality locations
- PaceCalculator continues with last valid samples
- UI displays accuracy warning
- System recovers when accuracy improves

---

## 5. Performance Requirements

### Test: Location Update Latency
**Given**: Active workout with GPS tracking
**When**: Location update arrives from hardware
**Then**:
- Delegate callback fires within 50ms of GPS sample
- Processing (validation, distance calc) completes <150ms
- Total latency GPS → UI update <200ms (constitution requirement)

---

### Test: Battery Efficiency
**Given**: 2-hour workout with continuous GPS
**When**: Monitor battery consumption
**Then**:
- GPS + location processing uses <15% battery per hour
- Watch sustains 6+ hours continuous tracking (constitution requirement)
- Location updates throttle to 1 Hz when pace stable

---

## 6. Edge Cases

### Test: Stationary Detection
**Given**: Runner stopped at traffic light (0 speed)
**When**: Multiple location updates at same coordinates
**Then**:
- Speed reported as 0 m/s or -1 (invalid)
- Distance does not accumulate
- PaceCalculator handles zero-speed gracefully
- Pace display shows "Stopped" or last valid pace

---

### Test: GPS Spike Rejection
**Given**: Stable running pace
**When**: Receive outlier location (100m jump in 1 second)
**Then**:
- GPSManager detects impossible speed (>15 m/s)
- Outlier rejected before distance accumulation
- PaceCalculator smoothing removes spike
- Total distance remains accurate

---

### Test: Very Long Workout
**Given**: Marathon distance run (26.2 miles)
**When**: Process 94,608 location updates (26.2 hours at 1 Hz)
**Then**:
- No memory leaks (sample buffer capped at 60)
- Total distance within ±2% (42,195m ±844m)
- No arithmetic overflow in calculations

---

## 7. Background Operation

### Test: Location Updates During Screen Off
**Given**: Active workout with watch screen off
**When**: User lowers wrist (screen dims/sleeps)
**Then**:
- Location updates continue uninterrupted
- `allowsBackgroundLocationUpdates` = true enables this
- Workout session maintains GPS tracking
- Battery consumption remains acceptable

---

## 8. Simulation vs Real Device

### Test: Simulator Behavior
**Given**: Running in Xcode Simulator
**When**: Start location updates
**Then**:
- Simulator provides mock locations (Cupertino default)
- Can simulate GPX routes for testing
- Real GPS hardware not available
- Contract tests use real devices only

**Note**: GPS contract tests MUST run on real Apple Watch hardware. Simulator testing insufficient for GPS validation.

---

## Mock Strategy for Unit Tests

```swift
protocol LocationManager {
    var delegate: CLLocationManagerDelegate? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }

    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

class MockLocationManager: LocationManager {
    var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    var distanceFilter: CLLocationDistance = 5.0

    var isUpdating = false
    var mockLocations: [CLLocation] = []

    func startUpdatingLocation() {
        isUpdating = true
        // Simulate location updates
        for location in mockLocations {
            delegate?.locationManager?(self, didUpdateLocations: [location])
        }
    }

    func stopUpdatingLocation() {
        isUpdating = false
    }

    // Test helpers
    func simulateLocation(coordinate: CLLocationCoordinate2D, accuracy: Double) {
        let location = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 10,
            timestamp: Date()
        )
        delegate?.locationManager?(self, didUpdateLocations: [location])
    }

    func simulateError(_ error: Error) {
        delegate?.locationManager?(self, didFailWithError: error)
    }
}
```

---

## Real Device Testing Requirements

CoreLocation contract tests MUST include real device validation:

1. **Apple Watch Series 6+ with GPS**
2. **Test Cases**:
   - Outdoor 400m track lap (known distance)
   - Start indoors (poor GPS) → move outdoors (good GPS)
   - Run under heavy tree cover (intermittent GPS)
   - Complete mile at steady pace, verify distance ±2%
3. **Validation**:
   - Compare total distance to known course markers
   - Verify pace readings match external GPS device
   - Confirm battery life meets 6+ hour requirement

---

## Performance Benchmarks

- **Location callback latency**: <50ms
- **Distance calculation**: <0.01ms per pair
- **Total GPS → UI pipeline**: <200ms (constitution requirement)
- **Memory per location**: ~80 bytes
- **Max sample buffer**: 60 locations (~5KB)

---

## Constitution Compliance

✅ **Native Performance**: CoreLocation is native iOS framework, optimized for Apple hardware
✅ **Battery Efficiency**: 1 Hz updates, distanceFilter, accuracy tuning per constitution
✅ **<200ms Latency**: GPS processing pipeline meets performance requirement
✅ **Offline Operation**: GPS functions without network connectivity
