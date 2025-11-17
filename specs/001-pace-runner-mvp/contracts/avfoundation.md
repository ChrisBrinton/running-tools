# AVFoundation Integration Contract

**Framework**: AVFoundation
**Platform**: watchOS 10.0+
**Purpose**: Audio tempo beats and voice alerts for pace guidance

## Contract Tests Required

Contract tests verify correct integration with AVFoundation for precise audio generation, mixing, and background playback during workouts.

---

## 1. Audio Session Configuration

### Test: Configure Audio Session for Workout
**Given**: Watch app launch
**When**: AudioEngine configures AVAudioSession
**Then**:
- Category = `.playback`
- Mode = `.default`
- Policy = `.longFormAudio` (watchOS background audio)
- Options = `[.mixWithOthers, .duckOthers]`
- Session activates successfully
- Return success

**Constitution**: Enables background audio during screen-off workouts

---

### Test: Audio Mixing with Music
**Given**: User playing music in Music app
**When**: AudioEngine starts tempo beats
**Then**:
- Music continues playing
- Tempo beats mix with music (`.mixWithOthers`)
- Both audible simultaneously
- No interruption of music playback

---

### Test: Audio Ducking During Voice Alerts
**Given**: Music playing with tempo beats
**When**: AudioEngine plays voice alert
**Then**:
- Music volume reduces automatically (`.duckOthers`)
- Voice alert clearly audible
- Music returns to normal volume after alert
- Tempo beats unaffected

---

## 2. Audio Engine Setup

### Test: Initialize AVAudioEngine
**Given**: Fresh AudioEngine instance
**When**: Setup called
**Then**:
- AVAudioEngine created
- AVAudioPlayerNode attached
- Player connected to main mixer
- Engine starts successfully
- Return success

---

### Test: Audio Format Configuration
**Given**: Audio engine setup
**When**: Configure audio format
**Then**:
- Sample rate = 44,100 Hz
- Channels = 1 (mono)
- Format = Float32 Linear PCM
- Connection uses correct format
- No format conversion errors

---

## 3. Tempo Beat Generation

### Test: Generate Beat Buffer
**Given**: AudioEngine initialized
**When**: Generate tempo beat buffer
**Then**:
- Buffer created with 10ms duration (441 samples at 44.1kHz)
- Contains 800Hz sine wave with envelope
- Amplitude = 0.3 (30% volume)
- Buffer size = 1.7KB
- Generation completes <1ms

---

### Test: Sample-Accurate Beat Scheduling
**Given**: Active audio engine
**When**: Schedule 10 beats at 180 BPM
**Then**:
- Each beat scheduled at absolute sample time
- Interval = 44,100 * 60 / 180 = 14,700 samples
- Timing accuracy ±5ms (constitution requirement)
- No cumulative drift over 6+ hours
- Beats play continuously without gaps

---

### Test: BPM Change During Playback
**Given**: Playing tempo beats at 180 BPM
**When**: Change to 170 BPM
**Then**:
- Current beats finish playing
- New beats scheduled at 170 BPM rate
- Transition smooth (no clicks or pops)
- Total restart time <200ms

---

## 4. Voice Alerts

### Test: Synthesize Voice Alert
**Given**: Active audio session
**When**: AudioEngine plays voice alert "Mile 1 complete"
**Then**:
- AVSpeechSynthesizer creates utterance
- Voice = en-US
- Rate = 1.1x default (slightly faster)
- Alert plays immediately
- Latency <500ms (constitution requirement)

---

### Test: Voice Alert Throttling
**Given**: Multiple pace deviation events in short time
**When**: Trigger 5 "speed up" alerts within 10 seconds
**Then**:
- Only first alert plays immediately
- Subsequent alerts throttled (30-second minimum)
- No audio spam
- User not overwhelmed

---

### Test: Voice Over Tempo Beats
**Given**: Tempo beats playing continuously
**When**: Voice alert fires
**Then**:
- Tempo beats continue uninterrupted
- Voice alert mixes over beats
- Both clearly audible
- No clipping or distortion

---

## 5. Background Audio

### Test: Audio Continues During Screen Off
**Given**: Active workout with tempo beats
**When**: Watch screen turns off (wrist down)
**Then**:
- Tempo beats continue playing
- Voice alerts still trigger
- `.longFormAudio` policy enables this
- Battery consumption remains acceptable

---

### Test: Audio Session Interruption
**Given**: Active tempo beats
**When**: Phone call received on paired iPhone
**Then**:
- Audio session interrupted
- Delegate receives `AVAudioSessionInterruptionNotification`
- Tempo pauses automatically
- Resumes after call ends (if `.shouldResume` option set)

---

## 6. Timing Precision

### Test: Beat Timing Accuracy
**Given**: Tempo beats at 180 BPM
**When**: Record actual beat intervals with external measurement
**Then**:
- Expected interval: 333.33ms (60,000ms / 180 BPM)
- Actual interval: 333.33ms ±5ms
- Meets constitution ±5ms requirement
- No drift over 1 hour (10,800 beats)

**Measurement**: Use external audio recording + analysis to verify timing

---

### Test: Long-Duration Timing Stability
**Given**: Continuous tempo beats for 6 hours
**When**: Measure cumulative drift
**Then**:
- Total beats: 64,800 (180 BPM × 60 min/hr × 6 hr)
- Cumulative drift: <30 seconds total
- Average error: <0.5ms per beat
- Constitution: Sustains 6+ hour operation

---

## 7. Error Handling

### Test: Audio Engine Start Failure
**Given**: Audio engine not started
**When**: Attempt to play tempo beats
**Then**:
- Detect engine not running
- Attempt to start engine
- If fails: Log error, display UI message
- Gracefully degrade (workout continues without audio)

---

### Test: Buffer Scheduling Failure
**Given**: Audio player node not playing
**When**: Attempt to schedule beat buffer
**Then**:
- Detect scheduling error
- Restart player node
- Resume scheduling
- No crash or audio glitch

---

### Test: Speech Synthesis Failure
**Given**: AVSpeechSynthesizer unavailable
**When**: Attempt to play voice alert
**Then**:
- Detect synthesis failure
- Log warning
- Skip alert (fail silently)
- Tempo beats unaffected

---

## 8. Performance Requirements

### Test: CPU Usage During Beats
**Given**: Active tempo beats at 180 BPM
**When**: Monitor CPU usage with Instruments
**Then**:
- CPU usage <5% on Apple Watch
- No sustained high CPU spikes
- Battery drain <10% per hour
- Constitution: Minimal CPU for battery efficiency

---

### Test: Memory Usage
**Given**: 1-hour workout with tempo beats
**When**: Monitor memory with Instruments
**Then**:
- Beat buffer: 1.7KB (constant)
- AVAudioEngine: <2MB
- Total audio engine memory: <5MB
- No memory leaks

---

### Test: Latency from Trigger to Playback
**Given**: Voice alert triggered by pace deviation
**When**: Measure time from trigger to first audio sample
**Then**:
- Total latency <500ms
- Utterance creation: <100ms
- Speech synthesis start: <400ms
- Meets constitution requirement

---

## 9. Edge Cases

### Test: Rapid BPM Changes
**Given**: Playing tempo beats
**When**: Change BPM 10 times in 5 seconds
**Then**:
- Each change processes correctly
- No audio artifacts or clicks
- Final BPM matches last setting
- No memory leaks from repeated restarts

---

### Test: Simultaneous Alerts
**Given**: Mile completion and pace deviation at same time
**When**: Both alerts trigger within 1 second
**Then**:
- First alert plays completely
- Second alert queued and plays after
- No overlapping speech
- Both messages delivered

---

### Test: Zero Volume Scenario
**Given**: User sets volume to 0%
**When**: Tempo beats and alerts fire
**Then**:
- Audio engine continues processing (no errors)
- No audible sound (volume = 0)
- User can increase volume and hear beats immediately
- No restart required

---

### Test: Headphone Disconnect
**Given**: User wearing Bluetooth headphones during workout
**When**: Headphones disconnect mid-workout
**Then**:
- Audio switches to watch speaker automatically
- Brief pause (<1 second)
- Tempo beats resume on speaker
- Voice alerts audible

---

## Mock Strategy for Unit Tests

```swift
protocol AudioSessionProtocol {
    func setCategory(_ category: AVAudioSession.Category,
                    mode: AVAudioSession.Mode,
                    policy: AVAudioSession.RouteSharingPolicy,
                    options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool) throws
}

class MockAudioSession: AudioSessionProtocol {
    var categorySet: AVAudioSession.Category?
    var optionsSet: AVAudioSession.CategoryOptions?
    var isActive: Bool = false

    func setCategory(_ category: AVAudioSession.Category,
                    mode: AVAudioSession.Mode,
                    policy: AVAudioSession.RouteSharingPolicy,
                    options: AVAudioSession.CategoryOptions) throws {
        categorySet = category
        optionsSet = options
    }

    func setActive(_ active: Bool) throws {
        isActive = active
    }
}

protocol AudioEngineProtocol {
    var isRunning: Bool { get }
    func attach(_ node: AVAudioNode)
    func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?)
    func start() throws
    func stop()
}

class MockAudioEngine: AudioEngineProtocol {
    var isRunning: Bool = false
    var attachedNodes: [AVAudioNode] = []

    func attach(_ node: AVAudioNode) {
        attachedNodes.append(node)
    }

    func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {
        // Mock connection
    }

    func start() throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}
```

---

## Real Device Testing Requirements

AVFoundation contract tests MUST include real device validation:

1. **Apple Watch Series 6+ running watchOS 10.0+**
2. **Test Cases**:
   - Start tempo beats, use external metronome app to verify 180 BPM accuracy
   - Play music, start workout, verify both audible and mixed correctly
   - Run 1-hour workout with screen off, verify audio continues
   - Trigger voice alerts, verify intelligibility and ducking
   - Measure battery drain over 2-hour workout
3. **Validation**:
   - Use audio recording app to capture and analyze timing
   - Verify no clicks, pops, or audio artifacts
   - Confirm battery life meets 6+ hour requirement

---

## Performance Benchmarks

- **Beat generation**: <1ms
- **Scheduling latency**: <10ms
- **Voice alert latency**: <500ms (constitution requirement)
- **Timing accuracy**: ±5ms (constitution requirement)
- **CPU usage**: <5% during active playback
- **Memory**: <5MB total
- **Battery**: <10% drain per hour

---

## Constitution Compliance

✅ **Timing Precision**: ±5ms tempo beat accuracy via sample-accurate scheduling
✅ **Battery Efficiency**: Minimal CPU, no Timer-based approaches
✅ **Background Operation**: `.longFormAudio` policy enables screen-off playback
✅ **6+ Hour Sustain**: Low CPU/memory usage supports marathon-length workouts
✅ **Audio Mixing**: `.mixWithOthers` + `.duckOthers` for music compatibility
