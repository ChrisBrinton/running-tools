# Multi-Window Pace Implementation

## Overview
Replaced single 10-second pace window with hierarchical multi-window system focused on hitting mile split targets.

## Architecture

### 1. Pace Windows (Priority Order)
1. **Split** (Highest Priority) - Current mile pace since last mile marker
   - Calculation: `(currentDistance - mileStartDistance) / (currentTime - mileStartTime)`
   - Most important: Primary goal is hitting mile split targets

2. **1mi** - Last completed mile pace
   - Shows actual pace achieved on previous mile
   - Validates you hit the target

3. **3min** - Rolling 3-minute window with EWMA smoothing
   - Medium-term trend for course corrections
   - Window: 180 seconds
   - Smoothing: Alpha = 0.3

4. **1min** - Rolling 1-minute window with EWMA smoothing
   - Short-term trend for immediate adjustments
   - Window: 60 seconds
   - Smoothing: Alpha = 0.3
   - Replaces old 10-second window (too noisy)

### 2. Priority-Based Alerting
Only alert on the **most important** window that's out of tolerance:

```
IF split pace out of tolerance:
    Alert on split (ignore other windows)
ELSE IF last mile pace out of tolerance:
    Alert on last mile (ignore 3min/1min)
ELSE IF 3min pace out of tolerance:
    Alert on 3min (ignore 1min)
ELSE IF 1min pace out of tolerance:
    Alert on 1min
ELSE:
    All on pace - no alert
```

This prevents short-term fluctuations from triggering alerts when overall split is good.

### 3. Color Coding
Each pace window is color-coded based on deviation from target:

- **Green**: Within tolerance (±tolerance seconds)
- **Yellow**: Moderate deviation (tolerance to 2× tolerance)
- **Red**: Significant deviation (>2× tolerance)
- **Gray**: No data yet

### 4. UI Layout (Watch Face)
```
┌─────────────────────────┐
│   Spt: 8:05  1mi: 8:10  │  ← Top row: Most important
│  3min:7:58  1min: 8:15  │  ← Bottom row: Real-time
├─────────────────────────┤
│ Target  Dist    Time    │  ← Stats row
│  8:00   2.3mi  18:24    │
├─────────────────────────┤
│ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░   │  ← Progress bar
├─────────────────────────┤
│      [Pause]            │  ← Controls
└─────────────────────────┘
```

## Code Changes

### New Files
- **PaceWindows.swift** - Model for 4 pace values with priority deviation logic

### Modified Files

#### PaceCalculator.swift
- Added `oneMinWindow: 60s` and `threeMinWindow: 180s` constants
- Added `oneMinutePace` and `threeMinutePace` computed properties
- Modified `calculateSmoothedPace()` to accept `windowDuration` parameter
- Keep samples for longest window (3 minutes)

#### WorkoutState.swift
- Added `paceWindows: PaceWindows` field
- Added `currentMileSplitStart: Double` - distance at mile start
- Added `currentMileSplitStartTime: TimeInterval` - time at mile start
- Added `splitPace` computed property - calculates current mile pace
- Kept `currentPace` for backward compatibility (marked deprecated)

#### WorkoutManager.swift (Watch App)
- Modified `handlePaceUpdate()`:
  - Populate all 4 pace windows from calculator + state
  - Use `PaceWindows.mostImportantDeviation()` for alert logic
  - Only alert on highest priority out-of-tolerance window

- Modified `handleMileTracking()`:
  - Use `splitPace` instead of `currentPace` for mile split recording
  - Reset split tracking when mile completes:
    - `currentMileSplitStart = currentDistance`
    - `currentMileSplitStartTime = elapsedTime`

#### ActiveWorkoutView.swift
- Redesigned to 2×2 pace grid
- Each pace shows label + value with color coding
- Reduced font sizes to fit all 4 paces
- Added `paceWindow()` helper for consistent formatting
- Added `colorForPace()` with 3-tier color system

## Benefits

### 1. **Less Alert Spam**
- Short-term GPS noise doesn't trigger alerts if split pace is good
- Focuses runner on what matters: hitting mile targets

### 2. **Better Situational Awareness**
- See all time scales at once
- Quickly identify if problem is short-term (adjust now) or long-term (fell behind)

### 3. **More Accurate Pacing**
- 1-minute window much smoother than 10-second
- 3-minute window shows true trend
- Split pace shows actual progress toward mile goal

### 4. **Hierarchical Feedback**
Example: Running a marathon at 8:00/mile target

**Scenario A: Short-term spike**
```
Spt: 8:02   (green - slightly slow but acceptable)
1mi: 8:00   (green - last mile was perfect)
3min: 8:05  (yellow - recent trend slow)
1min: 8:15  (red - just slowed down a lot)

Result: No alert (split pace in tolerance, just a momentary slowdown)
```

**Scenario B: Falling behind**
```
Spt: 8:25   (red - way behind on current mile)
1mi: 8:18   (red - last mile was slow)
3min: 8:20  (red - sustained slow trend)
1min: 8:22  (red - still slow)

Result: Alert "Speed up" (split pace out of tolerance = priority alert)
```

## Known Issues

### Build Error (Line 288)
```
error: cannot convert value of type '_' to expected argument type 'DispatchWorkItem'
    stateUpdateQueue.async { [weak self] in
```

**Cause**: Swift 6 MainActor isolation conflict with DispatchQueue.async closure

**Temporary Workaround Options**:
1. Remove `@MainActor` annotation from WorkoutManager
2. Use `Task.detached` instead of DispatchQueue
3. Mark closure as `@Sendable`

**Resolution Needed**: Fix async queue usage to compile with MainActor isolation.

## Testing Checklist

Once build error is resolved:

### Unit Tests
- [ ] Split pace calculates correctly at mile boundaries
- [ ] Each window (1min, 3min) filters samples correctly
- [ ] mostImportantDeviation() returns correct priority window
- [ ] Color coding matches deviation thresholds

### Integration Tests
- [ ] Mile split resets tracking on boundary cross
- [ ] Last mile pace persists after crossing mile marker
- [ ] All 4 paces update independently
- [ ] Priority alerts only trigger on highest priority window

### Real-World Tests
- [ ] Split pace stays stable throughout mile
- [ ] 1min pace responds to pace changes
- [ ] 3min pace smooths out GPS noise
- [ ] UI readable on watch during run
- [ ] Color coding provides clear feedback
- [ ] No alert spam during normal pace variations

## Future Enhancements

### Potential Improvements
1. **Configurable Windows** - Let user choose window durations
2. **Adaptive Smoothing** - Adjust alpha based on GPS accuracy
3. **Pace Prediction** - Project finish time based on current trends
4. **Historical Comparison** - Compare to previous run's paces
5. **Vibration Patterns** - Different patterns for each priority level

### Performance Optimizations
1. **Lazy Calculation** - Only calculate windows shown on screen
2. **Sample Decimation** - Keep fewer samples for longer windows
3. **GPU Rendering** - Hardware-accelerated UI updates
