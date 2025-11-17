# Audio Engine Specification

## Overview

The AudioEngine manages tempo beat generation and voice alerts during workouts. It must run reliably in the background, mix with music playback, and provide precise timing for tempo beats.

## Architecture

```
┌────────────────────────────────────────────────────────┐
│                   AudioEngine                          │
├────────────────────────────────────────────────────────┤
│                                                        │
│  ┌──────────────┐         ┌────────────────────────┐ │
│  │ TempoBeatGen │         │  VoiceAlertSystem      │ │
│  │              │         │                        │ │
│  │ AVAudioEngine│         │ AVSpeechSynthesizer    │ │
│  └──────┬───────┘         └────────┬───────────────┘ │
│         │                          │                  │
│         └──────────┬───────────────┘                  │
│                    │                                  │
│         ┌──────────▼───────────┐                     │
│         │  AVAudioSession      │                     │
│         │  (Mix with music)    │                     │
│         └──────────────────────┘                     │
│                                                        │
└────────────────────────────────────────────────────────┘
```

## Audio Session Configuration

### Setup

```swift
class AudioEngine {
    private var audioEngine: AVAudioEngine
    private var tempoPlayer: AVAudioPlayerNode
    private var speechSynthesizer: AVSpeechSynthesizer
    private var audioSession: AVAudioSession
    
    init() {
        self.audioEngine = AVAudioEngine()
        self.tempoPlayer = AVAudioPlayerNode()
        self.speechSynthesizer = AVSpeechSynthesizer()
        self.audioSession = AVAudioSession.sharedInstance()
        
        setupAudioSession()
        setupAudioEngine()
    }
    
    private func setupAudioSession() {
        do {
            // Configure for workout with music mixing
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
            
            try audioSession.setActive(true)
            
            print("Audio session configured")
            
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupAudioEngine() {
        // Attach tempo player node
        audioEngine.attach(tempoPlayer)
        
        // Connect to main mixer
        audioEngine.connect(
            tempoPlayer,
            to: audioEngine.mainMixerNode,
            format: nil
        )
        
        // Prepare and start engine
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            print("Audio engine started")
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
}
```

### Audio Session Options

- **`.mixWithOthers`**: Allow music apps to play simultaneously
- **`.duckOthers`**: Lower music volume during voice alerts
- **Mode**: `.default` for general audio playback
- **Category**: `.playback` for audio output

## Tempo Beat Generation

### Beat Synthesis

```swift
class TempoBeatGenerator {
    private let sampleRate: Double = 44100.0
    private var currentBPM: Int = 180
    
    // Generate a single beat sound (click)
    func generateBeat() -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        
        // Short click sound: 10ms at 800Hz
        let duration: Double = 0.01  // 10ms
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        guard let samples = buffer.floatChannelData?[0] else {
            return nil
        }
        
        // Generate sine wave click at 800Hz
        let frequency: Double = 800.0
        let amplitude: Float = 0.3  // 30% volume
        
        for i in 0..<Int(frameCount) {
            let sample = Double(i) / sampleRate
            samples[i] = amplitude * sin(2.0 * .pi * frequency * sample)
            
            // Apply envelope (fade in/out)
            let envelope = envelopeValue(for: i, total: Int(frameCount))
            samples[i] *= envelope
        }
        
        return buffer
    }
    
    // Envelope for smooth attack/release
    private func envelopeValue(for sample: Int, total: Int) -> Float {
        let position = Float(sample) / Float(total)
        
        if position < 0.1 {
            // Attack: 10% of duration
            return position / 0.1
        } else if position > 0.9 {
            // Release: last 10%
            return (1.0 - position) / 0.1
        } else {
            return 1.0
        }
    }
    
    // Calculate interval between beats
    func beatInterval(bpm: Int) -> TimeInterval {
        // BPM is beats per minute
        // Interval is seconds per beat
        return 60.0 / Double(bpm)
    }
}
```

### Tempo Beat Player

```swift
extension AudioEngine {
    private var isTempoPlaying: Bool = false
    private var tempoTimer: Timer?
    private var tempoBeatBuffer: AVAudioPCMBuffer?
    
    func startTempo(bpm: Int) {
        guard !isTempoPlaying else { return }
        
        currentBPM = bpm
        isTempoPlaying = true
        
        // Generate beat buffer
        tempoBeatBuffer = TempoBeatGenerator().generateBeat()
        
        // Start tempo player
        tempoPlayer.play()
        
        // Schedule beats using timer
        let interval = TempoBeatGenerator().beatInterval(bpm: bpm)
        
        tempoTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.playBeat()
        }
        
        // Also play first beat immediately
        playBeat()
    }
    
    func stopTempo() {
        guard isTempoPlaying else { return }
        
        isTempoPlaying = false
        tempoTimer?.invalidate()
        tempoTimer = nil
        
        tempoPlayer.stop()
    }
    
    func setTempoBPM(_ bpm: Int) {
        guard bpm != currentBPM else { return }
        
        currentBPM = bpm
        
        if isTempoPlaying {
            // Restart with new BPM
            stopTempo()
            startTempo(bpm: bpm)
        }
    }
    
    private func playBeat() {
        guard let buffer = tempoBeatBuffer,
              isTempoPlaying else { return }
        
        // Schedule buffer for playback
        tempoPlayer.scheduleBuffer(buffer, at: nil)
    }
}
```

### Alternative: More Precise Timing

For higher precision, use audio render callback:

```swift
class PreciseTempoBeatGenerator {
    private var phase: Double = 0.0
    private var beatsPerSecond: Double = 3.0  // 180 BPM = 3 beats/sec
    
    func generateSamples(
        buffer: AVAudioPCMBuffer,
        sampleRate: Double
    ) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        
        let frameCount = Int(buffer.frameLength)
        let samplesPerBeat = sampleRate / beatsPerSecond
        let clickDuration = 0.01 * sampleRate  // 10ms click
        
        for i in 0..<frameCount {
            let sampleInBeat = phase.truncatingRemainder(
                dividingBy: samplesPerBeat
            )
            
            if sampleInBeat < clickDuration {
                // Generate click
                let t = sampleInBeat / clickDuration
                let frequency: Double = 800.0
                let envelope = sin(t * .pi)  // Sine envelope
                
                samples[i] = Float(
                    0.3 * envelope * sin(2.0 * .pi * frequency * sampleInBeat / sampleRate)
                )
            } else {
                samples[i] = 0.0
            }
            
            phase += 1.0
        }
    }
}
```

## Voice Alerts

### Speech Synthesis

```swift
extension AudioEngine {
    func playVoiceAlert(_ message: String) {
        let utterance = AVSpeechUtterance(string: message)
        
        // Configure voice
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1  // Slightly faster
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Speak
        speechSynthesizer.speak(utterance)
    }
    
    func stopVoiceAlert() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
}
```

### Alert Messages

```swift
enum AlertMessage {
    case mileComplete(Int)
    case speedUp(current: Pace, target: Pace)
    case slowDown(current: Pace, target: Pace)
    case onPace
    case halfwayPoint
    case finalMile
    case workoutComplete
    
    var text: String {
        switch self {
        case .mileComplete(let mile):
            return "Mile \(mile) complete"
            
        case .speedUp(let current, let target):
            return "Speed up. Current pace \(current.formatted), target \(target.formatted)"
            
        case .slowDown(let current, let target):
            return "Slow down. Current pace \(current.formatted), target \(target.formatted)"
            
        case .onPace:
            return "On pace"
            
        case .halfwayPoint:
            return "Halfway point"
            
        case .finalMile:
            return "Final mile, finish strong"
            
        case .workoutComplete:
            return "Workout complete, great job"
        }
    }
}
```

### Alert Throttling

Prevent alert spam:

```swift
class AlertThrottler {
    private var lastAlertTime: [AlertMessage: Date] = [:]
    private let minimumInterval: TimeInterval = 30.0  // 30 seconds
    
    func shouldPlayAlert(_ message: AlertMessage) -> Bool {
        let now = Date()
        
        if let lastTime = lastAlertTime[message] {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed < minimumInterval {
                return false
            }
        }
        
        lastAlertTime[message] = now
        return true
    }
    
    func reset() {
        lastAlertTime.removeAll()
    }
}
```

## Audio Mixing

### Ducking Music During Alerts

The audio session automatically ducks other audio when configured with `.duckOthers` option. Voice alerts will temporarily lower music volume.

### Volume Control

```swift
extension AudioEngine {
    private var volume: Float = 0.7  // 70% default
    
    func setVolume(_ volume: Float) {
        self.volume = min(1.0, max(0.0, volume))
        
        // Update tempo player volume
        tempoPlayer.volume = self.volume
        
        // Speech synthesizer volume
        // (set per utterance in playVoiceAlert)
    }
    
    func getVolume() -> Float {
        return volume
    }
}
```

## Haptic Feedback

Complement audio with haptics on Apple Watch:

```swift
import WatchKit

extension AudioEngine {
    func playHapticForBeat() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }
    
    func playHapticForAlert(type: AlertMessage) {
        #if os(watchOS)
        switch type {
        case .mileComplete:
            WKInterfaceDevice.current().play(.success)
        case .speedUp, .slowDown:
            WKInterfaceDevice.current().play(.notification)
        case .workoutComplete:
            WKInterfaceDevice.current().play(.success)
        default:
            WKInterfaceDevice.current().play(.click)
        }
        #endif
    }
}
```

## Background Audio

### Enable Background Audio Capability

In Xcode project settings:
1. Select Watch App target
2. Signing & Capabilities
3. Add "Background Modes"
4. Enable "Audio, AirPlay, and Picture in Picture"

### Maintain Audio Session

```swift
func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
        return
    }
    
    switch type {
    case .began:
        // Audio interrupted (phone call, etc.)
        pauseAudio()
        
    case .ended:
        // Interruption ended
        guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
            return
        }
        
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if options.contains(.shouldResume) {
            resumeAudio()
        }
        
    @unknown default:
        break
    }
}

private func pauseAudio() {
    stopTempo()
    stopVoiceAlert()
}

private func resumeAudio() {
    if shouldBePlaying {
        startTempo(bpm: currentBPM)
    }
}
```

## Complete AudioEngine Implementation

```swift
class AudioEngine: ObservableObject {
    // MARK: - Properties
    
    @Published var isPlaying: Bool = false
    @Published var volume: Float = 0.7
    
    private var audioEngine: AVAudioEngine
    private var tempoPlayer: AVAudioPlayerNode
    private var speechSynthesizer: AVSpeechSynthesizer
    private var audioSession: AVAudioSession
    
    private var isTempoPlaying: Bool = false
    private var currentBPM: Int = 180
    private var tempoTimer: Timer?
    private var tempoBeatBuffer: AVAudioPCMBuffer?
    
    private let beatGenerator = TempoBeatGenerator()
    private let alertThrottler = AlertThrottler()
    
    // MARK: - Initialization
    
    init() {
        self.audioEngine = AVAudioEngine()
        self.tempoPlayer = AVAudioPlayerNode()
        self.speechSynthesizer = AVSpeechSynthesizer()
        self.audioSession = AVAudioSession.sharedInstance()
        
        setupAudioSession()
        setupAudioEngine()
        setupNotifications()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        handleAudioSessionInterruption(notification)
    }
    
    // MARK: - Public Interface
    
    func start(bpm: Int) {
        startTempo(bpm: bpm)
        isPlaying = true
    }
    
    func stop() {
        stopTempo()
        stopVoiceAlert()
        isPlaying = false
    }
    
    func playAlert(_ message: AlertMessage) {
        guard alertThrottler.shouldPlayAlert(message) else {
            return
        }
        
        playVoiceAlert(message.text)
        playHapticForAlert(type: message)
    }
    
    func updateTempo(bpm: Int) {
        setTempoBPM(bpm)
    }
    
    func setVolume(_ newVolume: Float) {
        volume = min(1.0, max(0.0, newVolume))
        tempoPlayer.volume = volume
    }
    
    // MARK: - Cleanup
    
    deinit {
        stop()
        audioEngine.stop()
        NotificationCenter.default.removeObserver(self)
    }
}
```

## Testing

### Unit Tests

```swift
class AudioEngineTests: XCTestCase {
    var audioEngine: AudioEngine!
    
    override func setUp() {
        super.setUp()
        audioEngine = AudioEngine()
    }
    
    override func tearDown() {
        audioEngine.stop()
        audioEngine = nil
        super.tearDown()
    }
    
    func testTempoStart() {
        audioEngine.start(bpm: 180)
        XCTAssertTrue(audioEngine.isPlaying)
    }
    
    func testTempoStop() {
        audioEngine.start(bpm: 180)
        audioEngine.stop()
        XCTAssertFalse(audioEngine.isPlaying)
    }
    
    func testBPMChange() {
        audioEngine.start(bpm: 180)
        audioEngine.updateTempo(bpm: 170)
        // Verify tempo changed (check currentBPM)
    }
    
    func testVolumeChange() {
        audioEngine.setVolume(0.5)
        XCTAssertEqual(audioEngine.volume, 0.5)
    }
}
```

### Manual Testing

1. **Tempo Beat Accuracy**
   - Set BPM to 180
   - Use metronome app to verify timing
   - Should be exactly 3 beats per second

2. **Music Mixing**
   - Start music in Music app
   - Start workout with tempo beats
   - Verify music plays simultaneously
   - Verify music ducks during voice alerts

3. **Background Operation**
   - Start workout
   - Turn off watch screen
   - Verify tempo continues playing

4. **Interruption Handling**
   - Start workout
   - Receive phone call
   - Answer and hang up
   - Verify tempo resumes

5. **Voice Alerts**
   - Trigger speed up alert
   - Verify clear speech
   - Verify throttling (no spam)

## Performance Optimization

### CPU Usage
- Pre-generate beat buffers
- Reuse buffers instead of generating each time
- Use efficient sine wave generation

### Memory Usage
- Limit number of queued buffers
- Release buffers when not needed
- Monitor audio engine memory

### Battery Impact
- Use simplest audio format possible
- Minimize audio processing
- Stop audio when workout paused

## Accessibility

### VoiceOver Support
- Pause/lower tempo during VoiceOver announcements
- Clear voice alert messages
- Haptic feedback for visual impairment

### Hearing Impairment
- Visual beat indicator on screen
- Strong haptic feedback option
- Adjustable volume range

## Future Enhancements

1. **Custom Beat Sounds**
   - Allow user to select different beat sounds
   - Woodblock, cowbell, click, beep

2. **Coaching Phrases**
   - Motivational messages
   - Form cues ("relax shoulders")
   - Breathing reminders

3. **Music Integration**
   - Tempo-matched playlist selection
   - Beat detection from playing music
   - Automatic BPM adjustment

4. **Advanced Haptics**
   - Rhythm patterns for pacing
   - Left/right alternating taps
   - Intensity matches effort level
