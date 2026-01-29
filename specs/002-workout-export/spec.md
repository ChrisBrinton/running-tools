# Feature Spec: Post-Workout Auto-Export

## Overview
Automatically capture detailed workout data when a running workout completes and export it as a structured JSON file to iCloud Drive for downstream consumption by an AI coaching assistant.

## Trigger
- Register an `HKObserverQuery` for `HKObjectType.workoutType()` with background delivery enabled
- On new workout detection, filter for `HKWorkoutActivityType.running` (including outdoor and treadmill)
- Process only workouts that haven't been previously exported (track exported workout UUIDs in UserDefaults or local store)

## Data to Capture

### Workout Summary
- Workout UUID
- Start date/time (ISO 8601)
- End date/time (ISO 8601)
- Total duration (seconds)
- Total distance (miles)
- Total energy burned (kcal)
- Average pace (min/mile)
- Source (app name / Apple Watch)
- Indoor vs outdoor flag

### Heart Rate Data
- Query `HKQuantityType(.heartRate)` for samples between workout start and end
- Compute: average HR, max HR, min HR, resting HR (if available)
- **Heart rate zones** — compute time-in-zone using standard 5-zone model:
  - Zone 1: < 60% max HR
  - Zone 2: 60-70% max HR
  - Zone 3: 70-80% max HR
  - Zone 4: 80-90% max HR
  - Zone 5: > 90% max HR
- Max HR: use `HKQuantityType(.restingHeartRate)` + age-based estimate, or allow user override in settings
- Include raw HR samples as array of `{ timestamp, bpm }` (for charting if needed)

### Per-Mile Splits
- Query `HKWorkoutRoute` for the workout
- Extract CLLocation points from route via `HKWorkoutRouteQuery`
- Compute elapsed time at each mile boundary
- Output: array of `{ mile: 1, pace: "7:45", elapsedTime: "7:45", avgHR: 148 }`
- For treadmill (no route data): use distance events from `HKWorkoutEvent` if available

### Route Data (optional, outdoor only)
- Array of `{ lat, lon, altitude, timestamp }` — sampled at reasonable intervals (every 5-10 seconds)
- Total elevation gain/loss

### Additional Metrics (if available)
- Running cadence (`HKQuantityType(.runningStrideLength)`, `.stepCount`)
- VO2 Max (most recent sample)
- Ground contact time
- Vertical oscillation

## Output Format

JSON file saved to iCloud Drive at: `iCloud Drive/Workouts/run-YYYY-MM-DD-HHMMSS.json`

```json
{
  "version": "1.0",
  "exportedAt": "2026-01-28T17:30:00Z",
  "workout": {
    "uuid": "...",
    "type": "outdoor_run",
    "startDate": "2026-01-28T16:00:00Z",
    "endDate": "2026-01-28T17:05:00Z",
    "duration": 3900,
    "distance": 8.2,
    "distanceUnit": "mi",
    "calories": 820,
    "avgPace": "7:52",
    "avgPaceSeconds": 472
  },
  "heartRate": {
    "avg": 152,
    "max": 171,
    "min": 118,
    "zones": [
      { "zone": 1, "label": "Recovery", "minutes": 2 },
      { "zone": 2, "label": "Easy", "minutes": 42 },
      { "zone": 3, "label": "Tempo", "minutes": 18 },
      { "zone": 4, "label": "Threshold", "minutes": 4 },
      { "zone": 5, "label": "Max", "minutes": 0 }
    ],
    "samples": [
      { "t": "2026-01-28T16:00:05Z", "bpm": 95 },
      "..."
    ]
  },
  "splits": [
    { "mile": 1, "pace": "7:45", "paceSeconds": 465, "avgHR": 148, "elapsed": "7:45" },
    { "mile": 2, "pace": "7:50", "paceSeconds": 470, "avgHR": 150, "elapsed": "15:35" },
    "..."
  ],
  "route": {
    "elevationGain": 120,
    "elevationLoss": 115,
    "elevationUnit": "ft",
    "points": [
      { "lat": 41.025, "lon": -73.628, "alt": 25.0, "t": "2026-01-28T16:00:05Z" }
    ]
  },
  "extras": {
    "avgCadence": 172,
    "vo2Max": 48.5
  }
}
```

## Implementation Notes

### HealthKit Permissions Required
- Read: Workouts, Heart Rate, Workout Route, Running Speed, Step Count, Resting Heart Rate, VO2 Max, Running Stride Length
- Background delivery entitlement for workout type

### iCloud Drive
- Use `FileManager.default.url(forUbiquityContainerIdentifier: nil)` to get the iCloud container
- Create `Workouts/` subdirectory if it doesn't exist
- Filename format: `run-YYYY-MM-DD-HHMMSS.json` (using workout start date)

### Deduplication
- Store exported workout UUIDs in `UserDefaults` (or a small local JSON file)
- Skip any workout that's already been exported

### Error Handling
- If HealthKit permissions not granted, surface a clear prompt to the user
- If iCloud Drive unavailable, fall back to local Documents directory
- If route data unavailable (treadmill), omit the route section — don't fail

### Settings (nice to have)
- Max HR override (for accurate zone calculation)
- Toggle auto-export on/off
- Export format preference (JSON is primary; plain text summary as bonus)

## Plain Text Summary (bonus output)

In addition to JSON, write a human-readable `.txt` summary for quick reference:

```
🏃 Run Summary — Jan 28, 2026

Distance: 8.2 mi | Duration: 1:05:00 | Avg Pace: 7:52/mi
Calories: 820 kcal | Elevation: +120 ft

Splits:
  Mile 1: 7:45 (HR 148)
  Mile 2: 7:50 (HR 150)
  Mile 3: 7:55 (HR 151)
  ...

Heart Rate: Avg 152 | Max 171
  Z1 Recovery:   2 min
  Z2 Easy:      42 min
  Z3 Tempo:     18 min
  Z4 Threshold:  4 min
  Z5 Max:        0 min

Cadence: 172 spm | VO2 Max: 48.5
```

Save as: `iCloud Drive/Workouts/run-YYYY-MM-DD-HHMMSS.txt`
