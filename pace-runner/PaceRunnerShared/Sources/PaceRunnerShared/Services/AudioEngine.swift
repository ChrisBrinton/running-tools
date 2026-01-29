import Foundation
import AVFoundation

/// Audio engine for tempo beats and voice alerts
///
/// Uses AVAudioSourceNode for sample-accurate metronome generation.
/// This approach generates audio directly in the render callback,
/// which is more reliable on watchOS than scheduling buffers.
///
/// Constitution compliance:
/// - ±5ms timing: Sample-accurate generation in render callback
/// - Battery efficiency: Minimal CPU in audio callback
/// - Background playback: .playback category for screen-off operation
public class AudioEngine: AudioEngineProtocol {

    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var speechSynthesizer: AVSpeechSynthesizer?

    public private(set) var isPlaying: Bool = false

    /// Whether voice synthesis is currently speaking
    public var isSpeaking: Bool {
        speechSynthesizer?.isSpeaking ?? false
    }

    // Audio format - will be set from mixer
    private var activeSampleRate: Double = 44100.0

    // Sound profile for configurable beat sounds
    private var soundProfile: BeatSoundProfile = .standard

    // Beat frequency modulation for pace feedback
    private let lowBeatFrequencyRatio: Float = 0.833  // ~50/60 - lower pitch for "too fast"
    private let highBeatFrequencyRatio: Float = 1.333 // ~80/60 - higher pitch for "too slow"
    private var currentFrequencyRatio: Float = 1.0    // Multiplier applied to profile frequency

    // Volume control
    private var currentVolume: Float = 0.0 // Metronome volume: 0.0 = silent, 1.0 = max
    private var masterVolume: Float = 1.0 // Master volume for voice: 0.0 = silent, 1.0 = max
    private var beatVolume: Float = 10.0 // Beat volume multiplier: 0.0 = silent, up to 30.0 = 30x boost

    private var currentBPM: Int = 0

    // Beat counting for emphasis (accessed from audio thread, use atomics)
    private var beatCounter: Int = 0
    private var emphasisBeatEnabled: Bool = false
    private var emphasisBeatInterval: Int = 2 // Every Nth beat
    private var audioBeatsEnabled: Bool = true

    // Audio generation state (accessed from audio thread)
    private var sampleTime: Int64 = 0
    private var samplesPerBeat: Int64 = 0
    private var nextBeatSampleTime: Int64 = 0
    private var currentBeatSamplePosition: Int = 0
    private var isInBeat: Bool = false
    private var currentBeatSamples: [Float] = []

    // Pre-computed beat samples
    private var regularBeatSamples: [Float] = []
    private var emphasisBeatSamples: [Float] = []

    // Voice alert throttling
    private var lastAlertTime: Date?
    private let alertThrottleInterval: TimeInterval = 30.0 // seconds

    // Important alert queue
    private var pendingImportantAlerts: [String] = []
    private var isProcessingImportantAlert = false

    // Dependency providers
    private let engineProvider: () -> AVAudioEngine
    private let speechProvider: () -> AVSpeechSynthesizer
    private let session: AVAudioSession
    private let dateProvider: () -> Date

    // Lock for thread-safe access to beat state
    private let stateLock = NSLock()

    public init(
        engineProvider: @escaping () -> AVAudioEngine = { AVAudioEngine() },
        playerProvider: @escaping () -> AVAudioPlayerNode = { AVAudioPlayerNode() },
        speechProvider: @escaping () -> AVSpeechSynthesizer = { AVSpeechSynthesizer() },
        session: AVAudioSession = .sharedInstance(),
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.engineProvider = engineProvider
        self.speechProvider = speechProvider
        self.session = session
        self.dateProvider = dateProvider
    }

    // MARK: - Sound Profile Configuration

    /// Configures the sound profile for beat generation
    /// - Parameter profile: The sound profile to use
    public func configureSoundProfile(_ profile: BeatSoundProfile) {
        stateLock.lock()
        defer { stateLock.unlock() }

        self.soundProfile = profile
        regenerateBeatSamples()
    }

    private func regenerateBeatSamples() {
        let regular = soundProfile.regularBeat
        regularBeatSamples = Self.generateBeatSamples(
            sampleRate: activeSampleRate,
            duration: regular.duration,
            frequency: regular.frequency * currentFrequencyRatio,
            amplitude: regular.amplitude,
            decayRate: regular.decayRate
        )

        let emphasis = soundProfile.emphasisBeat
        emphasisBeatSamples = Self.generateBeatSamples(
            sampleRate: activeSampleRate,
            duration: emphasis.duration,
            frequency: emphasis.frequency,
            amplitude: emphasis.amplitude,
            decayRate: emphasis.decayRate
        )

        print("AudioEngine: regenerated beat samples, regular=\(regularBeatSamples.count), emphasis=\(emphasisBeatSamples.count)")
    }

    // MARK: - Setup

    public func setup() throws {
        print("AudioEngine.setup: starting")

        // Configure audio session
        try configureAudioSession()

        // Create audio engine
        let engine = engineProvider()

        // Get the output format from the mixer
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        activeSampleRate = mixerFormat.sampleRate

        print("AudioEngine.setup: mixer sample rate = \(activeSampleRate)")

        // Generate beat samples at the correct sample rate
        regenerateBeatSamples()

        // Create source node with render callback
        // Use stereo format to match common hardware configurations
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: activeSampleRate,
            channels: 2
        ) else {
            throw AudioEngineError.bufferCreationFailed
        }

        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList)
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // Create speech synthesizer
        let synthesizer = speechProvider()

        // Store references
        self.audioEngine = engine
        self.sourceNode = source
        self.speechSynthesizer = synthesizer

        // Start the engine
        try engine.start()

        print("AudioEngine.setup: complete, engine running")
    }

    public func teardown() {
        print("AudioEngine.teardown: called")
        stopTempoBeats()
        audioEngine?.stop()
        if let source = sourceNode {
            audioEngine?.detach(source)
        }
        audioEngine = nil
        sourceNode = nil
        speechSynthesizer = nil
    }

    // MARK: - Audio Render Callback

    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // Get current state atomically
        stateLock.lock()
        let playing = isPlaying
        let samplesPerBeatLocal = samplesPerBeat
        var nextBeatTime = nextBeatSampleTime
        var beatPos = currentBeatSamplePosition
        var inBeat = isInBeat
        var beatSamples = currentBeatSamples
        let volume = currentVolume * beatVolume
        let beatsEnabled = audioBeatsEnabled
        let emphasisEnabled = emphasisBeatEnabled
        let emphasisInterval = emphasisBeatInterval
        var counter = beatCounter
        let regularSamples = regularBeatSamples
        let emphasisSamples = emphasisBeatSamples
        var currentSampleTime = sampleTime
        stateLock.unlock()

        for frame in 0..<Int(frameCount) {
            var sample: Float = 0.0

            if playing && samplesPerBeatLocal > 0 {
                // Check if we should start a new beat
                if currentSampleTime >= nextBeatTime && !inBeat {
                    counter += 1

                    // Determine which beat to play
                    let isEmphasis = emphasisEnabled && (counter % emphasisInterval == 0)

                    if isEmphasis {
                        beatSamples = emphasisSamples
                        inBeat = true
                        beatPos = 0
                    } else if beatsEnabled {
                        beatSamples = regularSamples
                        inBeat = true
                        beatPos = 0
                    } else {
                        // Silent beat - just advance timing
                        inBeat = false
                    }

                    // Schedule next beat
                    nextBeatTime = currentSampleTime + samplesPerBeatLocal
                }

                // Generate sample if in beat
                if inBeat && beatPos < beatSamples.count {
                    sample = beatSamples[beatPos] * volume
                    beatPos += 1
                    if beatPos >= beatSamples.count {
                        inBeat = false
                    }
                }

                currentSampleTime += 1
            }

            // Write to all channels (stereo)
            for buffer in ablPointer {
                guard let data = buffer.mData else { continue }
                let floatData = data.assumingMemoryBound(to: Float.self)
                floatData[frame] = sample
            }
        }

        // Save state back
        stateLock.lock()
        sampleTime = currentSampleTime
        nextBeatSampleTime = nextBeatTime
        currentBeatSamplePosition = beatPos
        isInBeat = inBeat
        currentBeatSamples = beatSamples
        beatCounter = counter
        stateLock.unlock()

        return noErr
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        // Use simple playback category - works better on watchOS
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            print("AudioEngine: Failed to set audio category: \(error)")
            // Try even simpler configuration
            try session.setCategory(.playback)
        }

        try session.setActive(true)
        print("AudioEngine: audio session configured")
    }

    // MARK: - Emphasis Beat Configuration

    /// Configures emphasis beat settings
    public func configureEmphasisBeat(enabled: Bool, interval: Int, audioBeatsEnabled: Bool) {
        print("AudioEngine.configureEmphasisBeat: enabled=\(enabled), interval=\(interval), audioBeatsEnabled=\(audioBeatsEnabled)")

        stateLock.lock()
        self.emphasisBeatEnabled = enabled
        self.emphasisBeatInterval = interval
        self.audioBeatsEnabled = audioBeatsEnabled
        stateLock.unlock()
    }

    // MARK: - Tempo Beats

    public func startTempoBeats(bpm: Int) throws {
        print("AudioEngine.startTempoBeats: bpm=\(bpm)")

        guard audioEngine != nil else {
            print("AudioEngine.startTempoBeats: ERROR - not setup!")
            throw AudioEngineError.notSetup
        }

        // Ensure engine is running
        if let engine = audioEngine, !engine.isRunning {
            print("AudioEngine.startTempoBeats: restarting engine")
            try engine.start()
        }

        stateLock.lock()
        currentBPM = bpm
        beatCounter = 0
        sampleTime = 0
        samplesPerBeat = Int64(activeSampleRate * 60.0 / Double(bpm))
        nextBeatSampleTime = 0 // Start immediately
        currentBeatSamplePosition = 0
        isInBeat = false
        currentBeatSamples = []
        isPlaying = true
        stateLock.unlock()

        print("AudioEngine.startTempoBeats: playing, samplesPerBeat=\(samplesPerBeat)")
    }

    public func stopTempoBeats() {
        stateLock.lock()
        isPlaying = false
        stateLock.unlock()
        print("AudioEngine.stopTempoBeats: stopped")
    }

    public func updateTempo(bpm: Int) throws {
        stateLock.lock()
        currentBPM = bpm
        samplesPerBeat = Int64(activeSampleRate * 60.0 / Double(bpm))
        stateLock.unlock()
    }

    // MARK: - Beat Sample Generation

    /// Generates samples for a beat sound
    public static func generateBeatSamples(
        sampleRate: Double,
        duration: Double,
        frequency: Float,
        amplitude: Float,
        decayRate: Float
    ) -> [Float] {
        let totalFrames = Int(sampleRate * duration)
        var samples = Array(repeating: Float.zero, count: totalFrames)

        for frame in 0..<totalFrames {
            let phase = 2.0 * Float.pi * frequency * Float(frame) / Float(sampleRate)
            let envelope = envelopeValue(frame: frame, totalFrames: totalFrames, decayRate: decayRate)
            samples[frame] = amplitude * sin(phase) * envelope
        }

        return samples
    }

    private static func envelopeValue(frame: Int, totalFrames: Int, decayRate: Float) -> Float {
        // Bass drum envelope: quick attack, exponential decay, smooth fade-out
        let attackFrames = totalFrames / 20 // 5% attack
        let fadeOutFrames = totalFrames / 10 // 10% fade-out
        let fadeOutStart = totalFrames - fadeOutFrames

        if frame < attackFrames {
            return Float(frame) / Float(attackFrames)
        } else if frame >= fadeOutStart {
            let decayProgress = (Float(frame) - Float(attackFrames)) / Float(totalFrames - attackFrames)
            let expDecay = exp(-decayRate * decayProgress)
            let fadeProgress = Float(frame - fadeOutStart) / Float(fadeOutFrames)
            let linearFade = 1.0 - fadeProgress
            return expDecay * linearFade
        } else {
            let decayProgress = (Float(frame) - Float(attackFrames)) / Float(totalFrames - attackFrames)
            return exp(-decayRate * decayProgress)
        }
    }

    // MARK: - Volume Control

    public func setMetronomeVolume(_ volume: Float) {
        stateLock.lock()
        currentVolume = max(0.0, min(1.0, volume))
        stateLock.unlock()
    }

    public func setMasterVolume(_ volume: Float) {
        masterVolume = max(0.0, min(1.0, volume))
    }

    public func setBeatVolume(_ volume: Float) {
        stateLock.lock()
        beatVolume = max(0.0, min(30.0, volume))
        stateLock.unlock()
    }

    public func updateVolumeForDeviation(
        deviationSeconds: Int,
        toleranceSeconds: Int = 5,
        maxDeviationSeconds: Int = 30,
        minVolume: Float = 0.3,
        maxVolume: Float = 1.0
    ) {
        if deviationSeconds <= toleranceSeconds {
            setMetronomeVolume(0.0)
        } else {
            let excessDeviation = Float(deviationSeconds - toleranceSeconds)
            let maxExcess = Float(maxDeviationSeconds - toleranceSeconds)
            let normalizedDeviation = min(1.0, excessDeviation / maxExcess)
            let volume = minVolume + normalizedDeviation * (maxVolume - minVolume)
            setMetronomeVolume(volume)
        }
    }

    public func updateBeatFrequency(isTooSlow: Bool) {
        let newRatio = isTooSlow ? highBeatFrequencyRatio : lowBeatFrequencyRatio
        guard newRatio != currentFrequencyRatio else { return }

        stateLock.lock()
        currentFrequencyRatio = newRatio
        regenerateBeatSamples()
        stateLock.unlock()
    }

    // MARK: - Debug Sounds

    public func playDebugSound() {
        // For source node approach, trigger a beat immediately
        stateLock.lock()
        nextBeatSampleTime = sampleTime // Trigger beat now
        isInBeat = false
        stateLock.unlock()
    }

    public func playDebugSoundsStartup() {
        playDebugSound()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.playDebugSound()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.playDebugSound()
        }
    }

    // MARK: - Voice Alerts

    public func playVoiceAlert(_ message: String) {
        let synthesizer: AVSpeechSynthesizer
        if let existing = speechSynthesizer {
            synthesizer = existing
        } else {
            let created = speechProvider()
            speechSynthesizer = created
            synthesizer = created
        }

        // Throttle alerts
        if let lastTime = lastAlertTime,
           dateProvider().timeIntervalSince(lastTime) < alertThrottleInterval {
            return
        }

        lastAlertTime = dateProvider()

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.volume = masterVolume
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        synthesizer.speak(utterance)
    }

    public func playImportantAlert(_ message: String) {
        pendingImportantAlerts.append(message)
        processImportantAlertQueue()
    }

    private func processImportantAlertQueue() {
        guard !isProcessingImportantAlert,
              !pendingImportantAlerts.isEmpty else {
            return
        }

        if isSpeaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.processImportantAlertQueue()
            }
            return
        }

        isProcessingImportantAlert = true
        let message = pendingImportantAlerts.removeFirst()

        let synthesizer: AVSpeechSynthesizer
        if let existing = speechSynthesizer {
            synthesizer = existing
        } else {
            let created = speechProvider()
            speechSynthesizer = created
            synthesizer = created
        }

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.volume = masterVolume
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        synthesizer.speak(utterance)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isProcessingImportantAlert = false
            self?.processImportantAlertQueue()
        }
    }

    // MARK: - Errors

    public enum AudioEngineError: Error {
        case notSetup
        case bufferCreationFailed
    }

    // MARK: - Testing Support

    public var tempoBPM: Int { currentBPM }

    public func configureForTesting(engine: AVAudioEngine, player: AVAudioPlayerNode, synthesizer: AVSpeechSynthesizer, buffer: AVAudioPCMBuffer) {
        audioEngine = engine
        speechSynthesizer = synthesizer
    }

    public func setTestState(bpm: Int, playing: Bool) {
        currentBPM = bpm
        isPlaying = playing
    }
}
