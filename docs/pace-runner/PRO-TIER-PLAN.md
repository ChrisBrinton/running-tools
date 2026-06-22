# PaceRunner Pro Tier Plan

One-time IAP (non-consumable) unlocking advanced features.

**Product ID:** `com.brintontech.pacerunner.pro`

---

## Free vs Pro Feature Matrix

| Feature | Free | Pro |
|---|---|---|
| Single-pace run configurations | Yes | Yes |
| Per-mile pace targets | Yes | Yes |
| Metronome audio beats | Yes | Yes |
| Voice pace alerts | Yes | Yes |
| GPS pace tracking | Yes | Yes |
| Workout history & sync | Yes | Yes |
| Multi-segment runs | - | Yes |
| PID-tuned pace algorithms | - | Yes |
| Dynamic audio (polyrhythm/BPM modulation) | - | Yes |

---

## Pro Feature 1: Multi-Segment Runs

### Concept
Allow runs composed of distinct segments with different pace targets, rather than uniform per-mile pacing. Enables interval workouts, progressive tempo runs, and race-simulation workouts.

### Data Model
- New `RunSegment` struct: `{ distance: Distance, targetPace: Pace, label: String? }`
- `RunConfiguration` gains optional `segments: [RunSegment]?`
- When `segments` is non-nil, `milePaces` is derived from segments for backward compat
- `requiresPro` returns `true` when `segments` is non-nil

### UI (iOS)
- `SegmentEditorView`: add/remove/reorder segments with drag handles
- Inline in ConfigurationEditView, toggled by "Use Segments" switch
- Segment preview bar showing pace gradient

### Watch
- Segment transitions shown on workout screen
- Audio announcement at segment boundaries ("Starting tempo segment at 7:30 pace")

---

## Pro Feature 2: Advanced Pace Algorithms

### Concept
Replace simple pace deviation alerts with a PID controller (from `Control System.md`) for smoother, more intelligent pace guidance.

### Components
- **PID Controller**: Proportional-Integral-Derivative feedback loop on pace error
- **TempoLock**: Lock cadence to a target BPM corridor, adjusting beat tempo in real-time based on PID output
- **Predictive pacing**: Use rolling pace trend to anticipate deviation before it happens

### Integration
- `PaceCalculator` gains `PIDPaceController` as optional strategy
- When Pro + PID enabled: pace corrections are gradual, not threshold-based
- Audio engine receives dynamic BPM adjustments from TempoLock

### Settings (Pro section)
- PID aggressiveness (conservative / moderate / aggressive)
- TempoLock sensitivity

---

## Pro Feature 3: Dynamic Audio

### Concept
Evolve the metronome from fixed-BPM clicks to musically rich, pace-reactive audio.

### Components
- **Polyrhythm profiles**: Predefined beat patterns (3-over-4, 5-over-4, swing) instead of straight clicks
- **BPM modulation**: TempoLock smoothly adjusts beat tempo based on pace deviation (from PID output)
- **Emphasis patterns**: More complex accent patterns beyond the current interval-based emphasis
- **Tone presets**: Different click sounds (woodblock, hi-hat, rim, electronic)

### Settings (Pro section)
- Polyrhythm selector
- BPM modulation range (e.g., +/- 5 BPM from target)
- Tone preset picker
- Preview button to audition patterns

---

## Implementation Phases

### Phase 1 (Current) - Entitlement Infrastructure
- [x] StoreKit 2 integration (EntitlementManager)
- [x] Entitlement sync via WatchConnectivity
- [x] Pro upgrade UI (SettingsView, ProUpgradeSheet)
- [x] Pro gate modifier (ProGateModifier)
- [ ] StoreKit configuration file (manual Xcode step)
- [ ] App Store Connect product setup

### Phase 2 - Multi-Segment Runs
- RunSegment model + RunConfiguration extension
- SegmentEditorView (iOS)
- Watch segment transition handling
- Segment-aware pace calculation

### Phase 3 - Advanced Pace Algorithms
- PID controller implementation
- TempoLock integration with AudioEngine
- PaceCalculator strategy pattern
- Pro settings UI

### Phase 4 - Dynamic Audio
- Polyrhythm beat generator
- BPM modulation pipeline
- Tone preset system
- Audio preview in settings

---

## App Store Setup Notes

### StoreKit Configuration File
Must be created via Xcode: File > New > StoreKit Configuration File
- Type: Non-Consumable
- Product ID: `com.brintontech.pacerunner.pro`
- Reference Name: PaceRunner Pro
- Price: TBD (suggest $4.99 or $6.99)

### App Store Connect
- Create In-App Purchase in App Store Connect
- Match product ID: `com.brintontech.pacerunner.pro`
- Submit for review with app update
- Sandbox testing available before submission

### Testing
- Use StoreKit configuration file for local testing in simulator
- Sandbox accounts for TestFlight testing
- `Transaction.currentEntitlements` works on both iOS and watchOS
