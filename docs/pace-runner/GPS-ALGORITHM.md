# GPS Algorithm Specification

## Overview

The GPS algorithm processes raw location data from CoreLocation to calculate accurate, smooth pace readings. It must handle noisy GPS data, signal loss, and varying accuracy conditions common during outdoor running.

## GPS Data Flow

```
CoreLocation
    ↓
Raw GPS Samples
    ↓
Validation & Filtering
    ↓
Outlier Rejection
    ↓
Rolling Window Smoothing
    ↓
Pace Calculation
    ↓
Distance Tracking
    ↓
UI Updates
```

## CoreLocation Configuration

### Location Manager Setup

```swift
class GPSManager: NSObject, CLLocationManagerDelegate {
    private let locationManager: CLLocationManager
    private weak var delegate: GPSManagerDelegate?
    
    private var lastLocation: CLLocation?
    private var totalDistance: Double = 0.0  // meters
    private var locations: [CLLocation] = []
    
    override init() {
        self.locationManager = CLLocationManager()
        super.init()
        
        configureLocationManager()
    }
    
    private func configureLocationManager() {
        locationManager.delegate = self
        
        // Optimized for running workouts
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5.0  // Update every 5 meters minimum
        
        #if os(watchOS)
        // Enable background updates on watch
        locationManager.allowsBackgroundLocationUpdates = true
        #endif
    }
    
    func requestPermissions() {
        #if os(iOS)
        locationManager.requestWhenInUseAuthorization()
        #elseif os(watchOS)
        locationManager.requestAlwaysAuthorization()
        #endif
    }
    
    func startTracking() {
        // Reset state
        lastLocation = nil
        totalDistance = 0.0
        locations.removeAll()
        
        // Start location updates
        locationManager.startUpdatingLocation()
    }
    
    func stopTracking() {
        locationManager.stopUpdatingLocation()
    }
}
```

## GPS Sample Validation

### Sample Quality Checks

```swift
extension GPSManager {
    private func isValidLocation(_ location: CLLocation) -> Bool {
        // Check basic validity
        guard location.horizontalAccuracy >= 0 else {
            // Negative accuracy means invalid
            return false
        }
        
        // Reject samples with poor accuracy
        guard location.horizontalAccuracy < 50.0 else {
            // More than 50m accuracy is too poor
            return false
        }
        
        // Reject old samples (stale data)
        let age = abs(location.timestamp.timeIntervalSinceNow)
        guard age < 10.0 else {
            // More than 10 seconds old
            return false
        }
        
        // Reject invalid speeds
        if location.speed >= 0 {
            // Speed available, check range
            // Max human running speed ~12 m/s (Usain Bolt)
            // Allow up to 15 m/s for safety
            guard location.speed < 15.0 else {
                return false
            }
        }
        
        return true
    }
    
    private func isLikelyIndoors(_ location: CLLocation) -> Bool {
        // Very poor horizontal accuracy suggests indoor/GPS blocked
        return location.horizontalAccuracy > 65.0
    }
}
```

### CLLocationManagerDelegate

```swift
extension GPSManager: CLLocationManagerDelegate {
    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        
        // Validate location
        guard isValidLocation(location) else {
            print("Invalid GPS sample: accuracy=\(location.horizontalAccuracy)m")
            return
        }
        
        // Process location
        processLocation(location)
    }
    
    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                delegate?.gpsManager(self, didEncounterError: .permissionDenied)
            case .locationUnknown:
                // Temporary issue, continue
                break
            default:
                delegate?.gpsManager(self, didEncounterError: .unknownError(error))
            }
        }
    }
}
```

## Distance Calculation

### Haversine Distance

```swift
extension GPSManager {
    private func calculateDistance(
        from: CLLocation,
        to: CLLocation
    ) -> Double {
        // Use built-in distance calculation (uses Haversine formula)
        return from.distance(from: to)
    }
    
    private func processLocation(_ location: CLLocation) {
        defer { lastLocation = location }
        
        guard let last = lastLocation else {
            // First location, no distance yet
            locations.append(location)
            delegate?.gpsManager(self, didUpdateLocation: location)
            return
        }
        
        // Calculate distance from last location
        let distance = calculateDistance(from: last, to: location)
        
        // Sanity check: reject unrealistic movements
        let timeDelta = location.timestamp.timeIntervalSince(last.timestamp)
        guard timeDelta > 0 else { return }
        
        let speed = distance / timeDelta  // meters per second
        
        // Maximum realistic running speed: 12 m/s
        // Add buffer for GPS noise: 15 m/s
        guard speed < 15.0 else {
            print("Rejected unrealistic movement: \(speed) m/s")
            return
        }
        
        // Accumulate distance
        totalDistance += distance
        
        // Store location
        locations.append(location)
        
        // Notify delegate
        delegate?.gpsManager(self, didUpdateLocation: location)
        delegate?.gpsManager(
            self,
            didUpdateDistance: Distance(meters: totalDistance)
        )
    }
}
```

## Pace Calculation

### PaceCalculator Class

```swift
class PaceCalculator {
    // Configuration
    private let windowSize: TimeInterval = 10.0  // 10 second rolling window
    private let minSampleCount: Int = 5  // Minimum samples for pace
    private let outlierThreshold: Double = 0.25  // 25% deviation
    
    // State
    private var samples: [GPSSample] = []
    private var currentPace: Pace?
    
    struct GPSSample {
        let timestamp: Date
        let location: CLLocation
        let speed: Double  // m/s
        
        init(location: CLLocation) {
            self.timestamp = location.timestamp
            self.location = location
            
            // Use location's speed if available and valid
            if location.speed >= 0 {
                self.speed = location.speed
            } else {
                self.speed = 0.0
            }
        }
        
        // Calculate pace from speed
        var pace: Pace {
            guard speed > 0 else {
                return Pace(minutes: 99, seconds: 59)
            }
            return Pace(secondsPerMeter: 1.0 / speed)
        }
    }
    
    func addSample(_ location: CLLocation) {
        let sample = GPSSample(location: location)
        samples.append(sample)
        
        // Remove old samples outside window
        let cutoff = Date().addingTimeInterval(-windowSize)
        samples.removeAll { $0.timestamp < cutoff }
        
        // Calculate new pace
        currentPace = calculateSmoothedPace()
    }
    
    func getCurrentPace() -> Pace? {
        return currentPace
    }
    
    func reset() {
        samples.removeAll()
        currentPace = nil
    }
}
```

### Smoothing Algorithm

```swift
extension PaceCalculator {
    private func calculateSmoothedPace() -> Pace? {
        guard samples.count >= minSampleCount else {
            return nil
        }
        
        // Step 1: Remove outliers
        let filtered = removeOutliers(from: samples)
        
        guard filtered.count >= minSampleCount else {
            return nil
        }
        
        // Step 2: Calculate weighted average
        return calculateWeightedAverage(from: filtered)
    }
    
    private func removeOutliers(from samples: [GPSSample]) -> [GPSSample] {
        // Calculate median pace
        let paces = samples.map { $0.pace.totalSeconds }
        let sorted = paces.sorted()
        
        guard !sorted.isEmpty else { return samples }
        
        let median: Double
        if sorted.count % 2 == 0 {
            let mid = sorted.count / 2
            median = Double(sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            median = Double(sorted[sorted.count / 2])
        }
        
        // Filter samples within threshold of median
        let threshold = median * outlierThreshold
        
        return samples.filter { sample in
            let pace = Double(sample.pace.totalSeconds)
            return abs(pace - median) <= threshold
        }
    }
    
    private func calculateWeightedAverage(from samples: [GPSSample]) -> Pace? {
        guard !samples.isEmpty else { return nil }
        
        // Weight recent samples more heavily
        var totalWeight: Double = 0.0
        var weightedSum: Double = 0.0
        
        let now = Date()
        
        for sample in samples {
            // Calculate age-based weight (newer = higher weight)
            let age = now.timeIntervalSince(sample.timestamp)
            let weight = exp(-age / windowSize)  // Exponential decay
            
            // Accuracy-based weight (better accuracy = higher weight)
            let accuracyWeight = 1.0 / max(sample.location.horizontalAccuracy, 1.0)
            
            let combinedWeight = weight * accuracyWeight
            
            let paceSeconds = Double(sample.pace.totalSeconds)
            weightedSum += paceSeconds * combinedWeight
            totalWeight += combinedWeight
        }
        
        guard totalWeight > 0 else { return nil }
        
        let averagePaceSeconds = Int(weightedSum / totalWeight)
        return Pace(totalSeconds: averagePaceSeconds)
    }
}
```

### Alternative: Kalman Filter

For more sophisticated smoothing:

```swift
class KalmanPaceFilter {
    // State
    private var estimate: Double = 0.0  // Current pace estimate (s/m)
    private var errorCovariance: Double = 1.0
    
    // Process noise and measurement noise
    private let processNoise: Double = 0.01
    private let measurementNoise: Double = 0.1
    
    func update(measurement: Double) -> Double {
        // Prediction step
        let predictedErrorCovariance = errorCovariance + processNoise
        
        // Update step
        let kalmanGain = predictedErrorCovariance / 
            (predictedErrorCovariance + measurementNoise)
        
        estimate = estimate + kalmanGain * (measurement - estimate)
        errorCovariance = (1.0 - kalmanGain) * predictedErrorCovariance
        
        return estimate
    }
    
    func reset() {
        estimate = 0.0
        errorCovariance = 1.0
    }
}

extension PaceCalculator {
    private var kalmanFilter = KalmanPaceFilter()
    
    private func calculateKalmanPace() -> Pace? {
        guard !samples.isEmpty else { return nil }
        
        // Get most recent speed
        guard let latest = samples.last else { return nil }
        
        // Convert to seconds per meter
        let measurement = 1.0 / max(latest.speed, 0.1)
        
        // Update Kalman filter
        let filtered = kalmanFilter.update(measurement: measurement)
        
        // Convert back to pace
        return Pace(secondsPerMeter: filtered)
    }
}
```

## Pace Status Detection

```swift
extension PaceCalculator {
    enum PaceStatus {
        case tooSlow(deviation: Int)
        case onTarget
        case tooFast(deviation: Int)
        
        var needsAlert: Bool {
            switch self {
            case .onTarget:
                return false
            default:
                return true
            }
        }
    }
    
    func checkPaceStatus(
        targetPace: Pace,
        tolerance: Int  // seconds
    ) -> PaceStatus {
        guard let current = currentPace else {
            return .onTarget
        }
        
        let deviation = current.totalSeconds - targetPace.totalSeconds
        
        if abs(deviation) <= tolerance {
            return .onTarget
        } else if deviation > 0 {
            // Current is slower than target
            return .tooSlow(deviation: deviation)
        } else {
            // Current is faster than target
            return .tooFast(deviation: -deviation)
        }
    }
}
```

## Mile Detection

### Accurate Mile Boundary Crossing

```swift
class MileTracker {
    private var totalDistance: Double = 0.0  // meters
    private var lastMileDistance: Double = 0.0  // meters at last mile
    private var currentMile: Int = 0
    
    private let metersPerMile: Double = 1609.34
    
    func updateDistance(_ newDistance: Double) -> Int? {
        totalDistance = newDistance
        
        let distanceSinceLastMile = totalDistance - lastMileDistance
        
        if distanceSinceLastMile >= metersPerMile {
            // Mile completed
            currentMile += 1
            lastMileDistance = totalDistance
            return currentMile
        }
        
        return nil
    }
    
    func getCurrentMile() -> Int {
        return currentMile
    }
    
    func getProgressInCurrentMile() -> Double {
        let distanceSinceLastMile = totalDistance - lastMileDistance
        return distanceSinceLastMile / metersPerMile
    }
    
    func reset() {
        totalDistance = 0.0
        lastMileDistance = 0.0
        currentMile = 0
    }
}
```

### Mile Split Calculation

```swift
struct MileSplitCalculator {
    private var mileStartTime: Date?
    private var mileStartDistance: Double = 0.0
    
    mutating func startMile(at time: Date, distance: Double) {
        mileStartTime = time
        mileStartDistance = distance
    }
    
    func calculateSplit(
        endTime: Date,
        endDistance: Double
    ) -> MileSplit? {
        guard let startTime = mileStartTime else { return nil }
        
        let duration = endTime.timeIntervalSince(startTime)
        let distance = endDistance - mileStartDistance
        
        // Calculate average pace for this mile
        let paceSeconds = Int(duration)
        let pace = Pace(totalSeconds: paceSeconds)
        
        return (duration: duration, pace: pace, distance: distance)
    }
}

typealias MileSplit = (duration: TimeInterval, pace: Pace, distance: Double)
```

## GPS Signal Loss Handling

### Fallback to Watch Motion

```swift
extension GPSManager {
    private var lastKnownPace: Pace?
    private var gpsLostTimestamp: Date?
    
    private func handleGPSLoss() {
        gpsLostTimestamp = Date()
        
        // Notify delegate
        delegate?.gpsManager(self, didLoseGPSSignal: true)
        
        // Fall back to pedometer-based estimation
        #if os(watchOS)
        startPedometerFallback()
        #endif
    }
    
    #if os(watchOS)
    private var pedometer: CMPedometer?
    
    private func startPedometerFallback() {
        guard CMPedometer.isDistanceAvailable() else { return }
        
        pedometer = CMPedometer()
        pedometer?.startUpdates(from: Date()) { data, error in
            guard let data = data,
                  let distance = data.distance?.doubleValue else {
                return
            }
            
            // Use pedometer distance
            self.totalDistance += distance
            
            // Use last known pace
            if let pace = self.lastKnownPace {
                self.delegate?.gpsManager(
                    self,
                    didEstimatePace: pace,
                    usingPedometer: true
                )
            }
        }
    }
    
    private func stopPedometerFallback() {
        pedometer?.stopUpdates()
        pedometer = nil
    }
    #endif
    
    private func handleGPSRestore() {
        #if os(watchOS)
        stopPedometerFallback()
        #endif
        
        gpsLostTimestamp = nil
        delegate?.gpsManager(self, didLoseGPSSignal: false)
    }
}
```

## Performance Optimization

### Memory Management

```swift
extension PaceCalculator {
    private let maxSampleHistory = 60  // Keep max 60 samples
    
    private func limitSampleHistory() {
        if samples.count > maxSampleHistory {
            // Keep only most recent samples
            samples = Array(samples.suffix(maxSampleHistory))
        }
    }
}
```

### GPS Power Management

```swift
extension GPSManager {
    private var isPaceStable: Bool = false
    
    func handleStablePace() {
        // If pace is stable, reduce GPS accuracy to save battery
        if isPaceStable {
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }
    }
    
    private func checkPaceStability() {
        // Check if pace has been consistent for 2 minutes
        let recentSamples = samples.suffix(24)  // Last 2 minutes at 5s intervals
        
        guard recentSamples.count >= 24 else {
            isPaceStable = false
            return
        }
        
        let paces = recentSamples.map { $0.pace.totalSeconds }
        let average = paces.reduce(0, +) / paces.count
        
        let variance = paces.map { pow(Double($0 - average), 2) }.reduce(0, +) / Double(paces.count)
        let stdDev = sqrt(variance)
        
        // If standard deviation < 5 seconds, pace is stable
        isPaceStable = stdDev < 5.0
    }
}
```

## Testing & Validation

### Unit Tests

```swift
class PaceCalculatorTests: XCTestCase {
    var calculator: PaceCalculator!
    
    override func setUp() {
        super.setUp()
        calculator = PaceCalculator()
    }
    
    func testPaceCalculation() {
        // Create mock locations with consistent pace
        let speed = 3.35  // m/s (8:00/mile pace)
        
        for i in 0..<10 {
            let location = createMockLocation(
                speed: speed,
                timestamp: Date().addingTimeInterval(Double(i))
            )
            calculator.addSample(location)
        }
        
        guard let pace = calculator.getCurrentPace() else {
            XCTFail("No pace calculated")
            return
        }
        
        // Should be approximately 8:00/mile
        XCTAssertEqual(pace.minutes, 8, accuracy: 0)
        XCTAssertEqual(pace.seconds, 0, accuracy: 5)
    }
    
    func testOutlierRejection() {
        // Add samples with one outlier
        let normalSpeed = 3.35  // 8:00/mile
        let outlierSpeed = 6.0   // Unrealistic spike
        
        for i in 0..<10 {
            let speed = (i == 5) ? outlierSpeed : normalSpeed
            let location = createMockLocation(
                speed: speed,
                timestamp: Date().addingTimeInterval(Double(i))
            )
            calculator.addSample(location)
        }
        
        // Pace should not be significantly affected by outlier
        guard let pace = calculator.getCurrentPace() else {
            XCTFail("No pace calculated")
            return
        }
        
        XCTAssertEqual(pace.minutes, 8, accuracy: 0)
    }
    
    private func createMockLocation(
        speed: Double,
        timestamp: Date
    ) -> CLLocation {
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: speed,
            timestamp: timestamp
        )
    }
}
```

### Integration Tests

1. **Stationary Test**: Device not moving, should report 0 pace
2. **Walking Test**: Slow walk (15-20 min/mile)
3. **Easy Run Test**: 9-10 min/mile pace
4. **Tempo Run Test**: 7-8 min/mile pace
5. **Sprint Test**: 5-6 min/mile pace

### Real-World Validation

Compare against known distances:
- Track workout (400m lap)
- Measured route with milestones
- Treadmill distance

## Error Scenarios

### No GPS Signal
- Indoor start
- Urban canyon
- Heavy tree cover

**Handling**: Display warning, use pedometer fallback

### Poor GPS Accuracy
- Accuracy > 50m

**Handling**: Continue tracking but show warning, increase smoothing

### Erratic GPS
- Jumping locations
- Speed spikes

**Handling**: Outlier rejection, Kalman filtering

## Future Enhancements

1. **Terrain Adjustment**: Adjust pace expectation for hills
2. **Wind Compensation**: Account for headwind/tailwind
3. **Stride Length**: Use stride data for better pace estimation
4. **Elevation Gain**: Track and display elevation changes
5. **GPS Track Recording**: Save full GPS track for mapping
