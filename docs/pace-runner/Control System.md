# Control Systems for Pace Feedback

## Overview

PaceRunner uses control system algorithms to provide intelligent, adaptive pace feedback during runs. Rather than simple threshold-based alerts, the system employs PID control for voice cues and phase-locked loop (superheterodyne) tempo adjustment to create a sophisticated feedback mechanism that adapts to runner behavior, terrain, and fatigue.

## Problem Statement

**Challenge**: Provide helpful pace guidance without alert fatigue or oscillation.

**Traditional approach limitations**:
- Binary threshold alerts ("too fast" / "too slow")
- Fixed alert frequency causes noise
- No adaptation to context (hills, fatigue, settling in)
- No gradual correction mechanism

**Control systems solution**:
- Continuous feedback via tempo beat adjustment
- Context-aware voice alerts with adaptive frequency
- Smooth transitions and oscillation damping
- Automatic adaptation to disturbances

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 Pace Feedback System                     │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐         ┌──────────────────────────┐ │
│  │  GPS Data    │────────→│  Moving Averages         │ │
│  │  - Raw pace  │         │  - 60s rolling avg       │ │
│  │  - Location  │         │  - 180s rolling avg      │ │
│  └──────────────┘         │  - 1 mile split avg      │ │
│                           └──────────┬───────────────┘ │
│                                      │                  │
│  ┌──────────────┐                   │                  │
│  │ Pedometer    │────────────────┐  │                  │
│  │ - Cadence    │                │  │                  │
│  └──────────────┘                │  │                  │
│                                   ↓  ↓                  │
│         ┌────────────────────────────────────────┐     │
│         │         PID Controller                  │     │
│         │  - Proportional: Current error         │     │
│         │  - Integral: Accumulated drift         │     │
│         │  - Derivative: Rate of change          │     │
│         └────────────┬───────────────────────────┘     │
│                      │                                  │
│                      ↓                                  │
│         ┌────────────────────────────┐                 │
│         │   Voice Cue Decision       │                 │
│         │   - Dead band filter       │                 │
│         │   - Urgency calculation    │                 │
│         │   - Frequency adaptation   │                 │
│         └────────────┬───────────────┘                 │
│                      │                                  │
│         ┌────────────▼───────────────┐                 │
│         │   Tempo Lock (PLL)         │                 │
│         │   - Phase detection        │                 │
│         │   - Frequency adjustment   │                 │
│         │   - Smooth convergence     │                 │
│         └────────────┬───────────────┘                 │
│                      │                                  │
│                      ↓                                  │
│         ┌────────────────────────────┐                 │
│         │   Audio Output              │                 │
│         │   - Voice alerts            │                 │
│         │   - Tempo beat @ N BPM     │                 │
│         └────────────────────────────┘                 │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## PID Control Theory

### Control Loop Fundamentals

**Process Variable (PV)**: Current pace (from 60s moving average)
**Setpoint (SP)**: Target pace for current mile
**Error (e)**: `e(t) = PV(t) - SP(t)` (seconds per mile deviation)
**Control Output (u)**: Alert urgency and frequency

### PID Equation

```
u(t) = Kp·e(t) + Ki·∫e(τ)dτ + Kd·(de/dt)
```

**Components**:
- **Proportional (P)**: `Kp·e(t)` - Immediate response to current error
- **Integral (I)**: `Ki·∫e(τ)dτ` - Corrects accumulated drift
- **Derivative (D)**: `Kd·(de/dt)` - Dampens oscillation

### Implementation

```swift
class PacePIDController {
    // Tunable gains
    var Kp: Double = 1.0    // Proportional gain
    var Ki: Double = 0.05   // Integral gain
    var Kd: Double = 0.8    // Derivative gain
    
    // State variables
    private var prevError: Double = 0.0
    private var integral: Double = 0.0
    private var lastUpdate: Date?
    
    // Anti-windup
    private let maxIntegral: Double = 30.0  // Max 30 seconds accumulated error
    
    func update(currentPace: Pace, targetPace: Pace, timestamp: Date) -> Double {
        // Calculate error in seconds
        let error = Double(currentPace.totalSeconds - targetPace.totalSeconds)
        
        guard let lastTime = lastUpdate else {
            // First update - initialize state
            lastUpdate = timestamp
            prevError = error
            return 0.0
        }
        
        // Calculate time delta
        let dt = timestamp.timeIntervalSince(lastTime)
        guard dt > 0 else { return 0.0 }
        
        // Proportional term
        let proportional = Kp * error
        
        // Integral term with anti-windup
        integral += error * dt
        integral = max(-maxIntegral, min(maxIntegral, integral))
        let integralTerm = Ki * integral
        
        // Derivative term
        let derivative = (error - prevError) / dt
        let derivativeTerm = Kd * derivative
        
        // PID output
        let output = proportional + integralTerm + derivativeTerm
        
        // Update state
        prevError = error
        lastUpdate = timestamp
        
        return output
    }
    
    func reset() {
        prevError = 0.0
        integral = 0.0
        lastUpdate = nil
    }
}
```

### Dead Band Filter

Prevents noise around target pace:

```swift
extension PacePIDController {
    func shouldAlert(pidOutput: Double, deadBand: Double = 5.0) -> Bool {
        return abs(pidOutput) > deadBand
    }
    
    func calculateUrgency(pidOutput: Double, maxOutput: Double = 15.0) -> Double {
        // Map PID output to 0-1 urgency scale
        let urgency = min(abs(pidOutput) / maxOutput, 1.0)
        return urgency
    }
}
```

## Phase-Locked Loop (Tempo Lock)

### Concept

Instead of discrete alerts, continuously adjust the tempo beat frequency to "pull" the runner toward target pace. The runner subconsciously adjusts their cadence to match the beat, creating smooth pace correction.

### Theory

**Phase-Locked Loop Components**:
1. **Phase Detector**: Compare current pace to target
2. **Loop Filter**: Smooth the error signal
3. **Voltage-Controlled Oscillator (VCO)**: Adjust tempo frequency

**Analogy**: Like a superheterodyne radio locking onto a carrier frequency.

### Implementation

```swift
class TempoLock {
    // Configuration
    var baseCadence: Int = 180           // Base SPM
    var lockBandwidth: Double = 5.0      // BPM adjustment rate
    var dampingFactor: Double = 0.7      // Critical damping
    var maxAdjustment: Int = 10          // Max ±10 BPM from base
    
    // State
    private var currentTempo: Double
    
    init(baseCadence: Int = 180) {
        self.baseCadence = baseCadence
        self.currentTempo = Double(baseCadence)
    }
    
    func update(
        currentPace: Pace,
        targetPace: Pace,
        detectedCadence: Int? = nil
    ) -> Int {
        // Calculate pace error (seconds per mile)
        let paceError = Double(currentPace.totalSeconds - targetPace.totalSeconds)
        
        // Convert pace error to cadence adjustment
        // If too slow (positive error), increase tempo
        // If too fast (negative error), decrease tempo
        let cadenceAdjustment = calculateCadenceAdjustment(paceError: paceError)
        
        // Target tempo with adjustment
        let targetTempo = Double(baseCadence) + cadenceAdjustment
        
        // Apply low-pass filter for smooth convergence
        let error = targetTempo - currentTempo
        let adjustment = error * dampingFactor * lockBandwidth / 60.0
        
        currentTempo += adjustment
        
        // Clamp to reasonable range
        let minTempo = Double(baseCadence - maxAdjustment)
        let maxTempo = Double(baseCadence + maxAdjustment)
        currentTempo = max(minTempo, min(maxTempo, currentTempo))
        
        return Int(currentTempo.rounded())
    }
    
    private func calculateCadenceAdjustment(paceError: Double) -> Double {
        // Mapping: 10 seconds pace error → ~3 BPM adjustment
        // This is tunable based on testing
        let sensitivity = 0.3  // BPM per second of pace error
        return -paceError * sensitivity  // Negative because slower pace needs faster cadence
    }
    
    func reset() {
        currentTempo = Double(baseCadence)
    }
}
```

### Phase Detection with Real Cadence

If pedometer cadence is available, use it for better convergence:

```swift
extension TempoLock {
    func updateWithDetectedCadence(
        currentPace: Pace,
        targetPace: Pace,
        detectedCadence: Int
    ) -> Int {
        // Phase error: difference between detected and desired cadence
        let paceError = Double(currentPace.totalSeconds - targetPace.totalSeconds)
        let desiredCadence = Double(baseCadence) - paceError * 0.3
        
        let phaseError = desiredCadence - Double(detectedCadence)
        
        // Adjust tempo to converge with detected cadence
        currentTempo += phaseError * dampingFactor * lockBandwidth / 60.0
        
        // Clamp
        let minTempo = Double(baseCadence - maxAdjustment)
        let maxTempo = Double(baseCadence + maxAdjustment)
        currentTempo = max(minTempo, min(maxTempo, currentTempo))
        
        return Int(currentTempo.rounded())
    }
}
```

## Hybrid System Integration

### Combined Controller

```swift
class PaceFeedbackSystem: ObservableObject {
    // Sub-systems
    private let pid = PacePIDController()
    private let tempoLock = TempoLock()
    
    // Configuration
    private let deadBand: Double = 5.0        // ±5 seconds no alert zone
    private let minCueInterval: Double = 15.0 // Minimum 15s between voice cues
    private let maxCueInterval: Double = 60.0 // Maximum 60s between voice cues
    
    // State
    private var lastVoiceCue: Date?
    @Published var currentTempoBPM: Int = 180
    
    struct FeedbackOutput {
        let tempoBPM: Int
        let voiceCue: VoiceCue?
        let pidOutput: Double
        let urgency: Double
    }
    
    enum VoiceCue {
        case speedUp(current: Pace, target: Pace, urgency: Double)
        case slowDown(current: Pace, target: Pace, urgency: Double)
    }
    
    func update(
        currentPace: Pace,
        targetPace: Pace,
        detectedCadence: Int?,
        timestamp: Date
    ) -> FeedbackOutput {
        // 1. Update PID controller
        let pidOutput = pid.update(
            currentPace: currentPace,
            targetPace: targetPace,
            timestamp: timestamp
        )
        
        // 2. Update tempo lock
        let newTempo: Int
        if let cadence = detectedCadence {
            newTempo = tempoLock.updateWithDetectedCadence(
                currentPace: currentPace,
                targetPace: targetPace,
                detectedCadence: cadence
            )
        } else {
            newTempo = tempoLock.update(
                currentPace: currentPace,
                targetPace: targetPace
            )
        }
        currentTempoBPM = newTempo
        
        // 3. Determine voice cue
        let voiceCue = determineVoiceCue(
            pidOutput: pidOutput,
            currentPace: currentPace,
            targetPace: targetPace,
            timestamp: timestamp
        )
        
        // 4. Calculate urgency for UI/logging
        let urgency = pid.calculateUrgency(pidOutput: pidOutput)
        
        return FeedbackOutput(
            tempoBPM: newTempo,
            voiceCue: voiceCue,
            pidOutput: pidOutput,
            urgency: urgency
        )
    }
    
    private func determineVoiceCue(
        pidOutput: Double,
        currentPace: Pace,
        targetPace: Pace,
        timestamp: Date
    ) -> VoiceCue? {
        // Check dead band
        guard pid.shouldAlert(pidOutput: pidOutput, deadBand: deadBand) else {
            return nil
        }
        
        // Calculate urgency and required interval
        let urgency = pid.calculateUrgency(pidOutput: pidOutput)
        let requiredInterval = maxCueInterval - (urgency * (maxCueInterval - minCueInterval))
        
        // Check if enough time has passed since last cue
        if let lastCue = lastVoiceCue {
            let timeSinceLast = timestamp.timeIntervalSince(lastCue)
            guard timeSinceLast >= requiredInterval else {
                return nil
            }
        }
        
        // Generate voice cue
        lastVoiceCue = timestamp
        
        if pidOutput > 0 {
            // Too slow
            return .speedUp(current: currentPace, target: targetPace, urgency: urgency)
        } else {
            // Too fast
            return .slowDown(current: currentPace, target: targetPace, urgency: urgency)
        }
    }
    
    func reset() {
        pid.reset()
        tempoLock.reset()
        lastVoiceCue = nil
    }
}
```

## Adaptive Tuning

### Context-Aware Gains

Different PID gains for different run phases:

```swift
extension PacePIDController {
    enum RunPhase {
        case settling    // First 2 miles
        case steady      // Middle miles
        case finishing   // Final 2 miles
    }
    
    func adjustGains(for phase: RunPhase) {
        switch phase {
        case .settling:
            // More damping, less aggressive
            Kp = 0.8
            Ki = 0.03
            Kd = 1.0   // Higher derivative for stability
            
        case .steady:
            // Standard gains
            Kp = 1.0
            Ki = 0.05
            Kd = 0.8
            
        case .finishing:
            // More aggressive, push to finish
            Kp = 1.2
            Ki = 0.08
            Kd = 0.6   // Less damping, quicker response
        }
    }
}
```

### Terrain Adaptation

```swift
extension PacePIDController {
    func adjustForTerrain(elevationGain: Double, timeWindow: TimeInterval) {
        // Calculate grade
        let grade = elevationGain / (timeWindow * 2.0)  // Rough estimation
        
        if abs(grade) > 0.03 {  // Significant hill (>3% grade)
            // Reduce gains to avoid fighting terrain
            Kp *= 0.7
            Ki *= 0.5
            
            // Increase dead band
            // (handled by caller)
        }
    }
}
```

## Tuning Guide

### Initial Gain Selection

**Ziegler-Nichols Method** (simplified):
1. Set Ki = 0, Kd = 0
2. Increase Kp until system oscillates
3. Record critical gain Kc and oscillation period Pc
4. Calculate:
   - `Kp = 0.6 * Kc`
   - `Ki = 1.2 * Kc / Pc`
   - `Kd = 0.075 * Kc * Pc`

**Practical Starting Values** (from testing):
- **Kp**: 1.0 (1:1 response to error)
- **Ki**: 0.05 (slow integration)
- **Kd**: 0.8 (moderate damping)

### Tuning Symptoms

| Symptom | Problem | Solution |
|---------|---------|----------|
| Constant speed-up/slow-down oscillation | Kp too high | Reduce Kp by 20% |
| Gradual drift from target | Ki too low | Increase Ki by 50% |
| Overshoot after corrections | Kd too low | Increase Kd by 30% |
| Slow response to pace changes | Kp too low | Increase Kp by 20% |
| Alert spam | Dead band too small | Increase to 7-10s |

### Logging for Tuning

```swift
struct PIDLog: Codable {
    let timestamp: Date
    let currentPace: Int      // seconds per mile
    let targetPace: Int
    let error: Double
    let proportional: Double
    let integral: Double
    let derivative: Double
    let pidOutput: Double
    let tempoBPM: Int
    let voiceCueGiven: Bool
}

extension PaceFeedbackSystem {
    func logState(
        currentPace: Pace,
        targetPace: Pace,
        output: FeedbackOutput
    ) -> PIDLog {
        return PIDLog(
            timestamp: Date(),
            currentPace: currentPace.totalSeconds,
            targetPace: targetPace.totalSeconds,
            error: Double(currentPace.totalSeconds - targetPace.totalSeconds),
            proportional: pid.Kp * Double(currentPace.totalSeconds - targetPace.totalSeconds),
            integral: pid.Ki * pid.integral,
            derivative: pid.Kd * (Double(currentPace.totalSeconds - targetPace.totalSeconds) - pid.prevError),
            pidOutput: output.pidOutput,
            tempoBPM: output.tempoBPM,
            voiceCueGiven: output.voiceCue != nil
        )
    }
}
```

## Moving Average Selection

### Which Average for What

**60-second rolling average** (Primary for PID):
- **Use**: PID process variable
- **Rationale**: Responsive enough to catch trends, smooth enough to avoid GPS noise
- **Update rate**: Every GPS sample (1 Hz)

**180-second rolling average** (Trend detection):
- **Use**: Feed into integral term calculation
- **Rationale**: Detects sustained drift (fatigue, hills)
- **Update rate**: Every 5 seconds

**1-mile split average** (Reference):
- **Use**: Summary display, not real-time control
- **Rationale**: Too coarse for active feedback
- **Update rate**: Per mile completion

### Moving Average Implementation

```swift
class MovingAverage {
    private var samples: [(value: Double, timestamp: Date)] = []
    private let windowSize: TimeInterval
    
    init(windowSize: TimeInterval) {
        self.windowSize = windowSize
    }
    
    func addSample(value: Double, timestamp: Date) {
        samples.append((value, timestamp))
        
        // Remove samples outside window
        let cutoff = timestamp.addingTimeInterval(-windowSize)
        samples.removeAll { $0.timestamp < cutoff }
    }
    
    func getCurrentAverage() -> Double? {
        guard !samples.isEmpty else { return nil }
        
        let sum = samples.reduce(0.0) { $0 + $1.value }
        return sum / Double(samples.count)
    }
    
    func reset() {
        samples.removeAll()
    }
}
```

## Testing Strategy

### Unit Tests

```swift
class PIDControllerTests: XCTestCase {
    func testProportionalResponse() {
        let pid = PacePIDController()
        pid.Kp = 1.0
        pid.Ki = 0.0
        pid.Kd = 0.0
        
        let current = Pace(minutes: 8, seconds: 10)
        let target = Pace(minutes: 8, seconds: 0)
        
        let output = pid.update(
            currentPace: current,
            targetPace: target,
            timestamp: Date()
        )
        
        // Should be approximately 10 (10 seconds error * Kp=1.0)
        XCTAssertEqual(output, 10.0, accuracy: 0.1)
    }
    
    func testIntegralWindup() {
        let pid = PacePIDController()
        
        // Sustain error for extended period
        let current = Pace(minutes: 9, seconds: 0)
        let target = Pace(minutes: 8, seconds: 0)
        var timestamp = Date()
        
        for _ in 0..<100 {
            timestamp = timestamp.addingTimeInterval(1.0)
            _ = pid.update(currentPace: current, targetPace: target, timestamp: timestamp)
        }
        
        // Integral should be clamped
        XCTAssertLessThanOrEqual(abs(pid.integral), pid.maxIntegral)
    }
}
```

### Integration Tests

Test complete feedback loop:

```swift
func testFeedbackLoop() {
    let system = PaceFeedbackSystem()
    
    var currentPace = Pace(minutes: 8, seconds: 15)
    let targetPace = Pace(minutes: 8, seconds: 0)
    var timestamp = Date()
    
    var outputs: [PaceFeedbackSystem.FeedbackOutput] = []
    
    // Simulate 2 minutes of running
    for _ in 0..<120 {
        timestamp = timestamp.addingTimeInterval(1.0)
        
        let output = system.update(
            currentPace: currentPace,
            targetPace: targetPace,
            detectedCadence: 175,
            timestamp: timestamp
        )
        
        outputs.append(output)
        
        // Simulate runner responding to feedback
        // Tempo pulls runner toward target
        let tempoEffect = Double(output.tempoBPM - 180) * 0.1
        currentPace = Pace(totalSeconds: currentPace.totalSeconds - Int(tempoEffect))
    }
    
    // Verify convergence
    XCTAssertLessThan(abs(currentPace.totalSeconds - targetPace.totalSeconds), 5)
}
```

### Real-World Testing Protocol

**Phase 1: PID Tuning**
1. Track run with logging enabled
2. Export PID component data
3. Plot P, I, D terms over time
4. Identify dominant component during bad feedback
5. Adjust gains
6. Repeat

**Phase 2: Tempo Lock Validation**
1. Run with pedometer cadence logging
2. Track correlation between tempo changes and pace corrections
3. Measure convergence time (how long to reach target pace)
4. Validate subjective feel (does beat feel natural?)

**Phase 3: Hybrid System**
1. Run complete workout with both systems active
2. Count voice cues (target: 2-4 per mile for off-pace running)
3. Measure tempo variation (should stay within ±5 BPM)
4. Subjective: Is feedback helpful without being annoying?

## Performance Considerations

### Computational Complexity

- PID update: O(1) - simple arithmetic
- Moving average: O(n) where n = samples in window, but typically < 200
- Tempo lock: O(1) - simple filtering

**Update frequency**: 1 Hz (every GPS sample) is sufficient

### Battery Impact

Minimal - mathematical operations are negligible compared to:
- GPS updates
- Audio generation
- UI updates

### Memory Usage

```swift
// Typical memory footprint
sizeof(PacePIDController) = ~100 bytes
sizeof(TempoLock) = ~50 bytes
sizeof(MovingAverage) * 3 = ~5KB (for sample storage)

Total: < 10KB for control systems
```

## Future Enhancements

### Machine Learning Integration

**Learn runner-specific gains**:
- Track which gains work best for each runner
- Adapt to individual response characteristics
- Account for fitness level improvements

### Predictive Control

**Model Predictive Control (MPC)**:
- Predict pace trajectory based on terrain ahead
- Adjust feedback proactively
- Account for upcoming hills, turns

### Multi-Variable Control

**Additional inputs**:
- Heart rate (avoid overexertion)
- Power meter (effort-based pacing)
- Wind speed (environmental factors)

### Adaptive Dead Band

```swift
func calculateAdaptivDeadBand(
    runPhase: RunPhase,
    terrainVariability: Double,
    fatigueLevel: Double
) -> Double {
    var deadBand = 5.0  // Base
    
    // Wider during settling
    if case .settling = runPhase {
        deadBand = 7.0
    }
    
    // Wider on variable terrain
    deadBand += terrainVariability * 2.0
    
    // Wider when fatigued
    deadBand += fatigueLevel * 3.0
    
    return min(deadBand, 15.0)  // Max 15s
}
```

## References

### Control Theory
- Åström, K. J., & Hägglund, T. (2006). *Advanced PID Control*
- Franklin, G. F., Powell, J. D., & Emami-Naeini, A. (2019). *Feedback Control of Dynamic Systems*

### Phase-Locked Loops
- Best, R. E. (2007). *Phase-Locked Loops: Design, Simulation, and Applications*
- Gardner, F. M. (2005). *Phaselock Techniques*

### Athletic Performance
- Seiler, S. (2010). "What is best practice for training intensity and duration distribution in endurance athletes?"
- Tucker, R., & Noakes, T. D. (2009). "The physiological regulation of pacing strategy during exercise"

## Appendix: Quick Tuning Reference

### Starting Configuration
```swift
let system = PaceFeedbackSystem()

// PID Gains
system.pid.Kp = 1.0
system.pid.Ki = 0.05
system.pid.Kd = 0.8

// Tempo Lock
system.tempoLock.baseCadence = 180
system.tempoLock.lockBandwidth = 5.0
system.tempoLock.dampingFactor = 0.7
system.tempoLock.maxAdjustment = 10

// Dead band
system.deadBand = 5.0

// Cue intervals
system.minCueInterval = 15.0
system.maxCueInterval = 60.0
```

### Troubleshooting Table

| Issue | Check | Fix |
|-------|-------|-----|
| Too many voice cues | Dead band, min interval | Increase both |
| Oscillating pace | Kp, Kd | Reduce Kp, increase Kd |
| Drift from target | Ki | Increase Ki |
| Tempo feels jerky | Damping factor | Increase to 0.8-0.9 |
| Slow correction | Kp, lock bandwidth | Increase both |
| Overshoot | Kd, damping | Increase both |