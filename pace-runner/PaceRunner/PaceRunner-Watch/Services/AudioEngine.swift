import Foundation
import AVFoundation
import PaceRunnerShared

/// Audio engine for tempo beats and voice alerts
///
/// Responsibilities:
/// - Generate tempo beats (bass drum sound at target cadence)
/// - Schedule beats with sample-accurate timing (±5ms)
/// - Synthesize voice alerts via AVSpeechSynthesizer
/// - Mix audio with music from other apps
/// - Adaptive volume: silent when on pace, louder when off pace
///
/// Constitution compliance:
/// - ±5ms timing: Sample-accurate scheduling, no Timer-based approach
/// - Battery efficiency: Pre-computed buffers, minimal CPU
/// - Background playback: .longFormAudio policy for screen-off operation
///
/// Reference: specs/001-pace-runner-mvp/contracts/avfoundation.md
class AudioEngine: AudioEngineProtocol {

    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var speechSynthesizer: AVSpeechSynthesizer?

    private(set) var isPlaying: Bool = false

    /// Whether voice synthesis is currently speaking
    var isSpeaking: Bool {
        speechSynthesizer?.isSpeaking ?? false
    }

    // Audio format constants
    private let sampleRate: Double = 44100.0
    // Bass drum sound: low frequency with punch
    private let baseBeatFrequency: Float = 60.0 // Hz - normal bass drum
    private let lowBeatFrequency: Float = 50.0  // Hz - lower pitch for "too slow"
    private let highBeatFrequency: Float = 80.0 // Hz - higher pitch for "too fast"
    private var currentBeatFrequency: Float = 60.0 // Current active frequency
    private let beatDuration: Double = 0.08 // 80ms - longer for bass thump
    private let beatAmplitude: Float = 1.0 // Base amplitude for waveform generation

    // Emphasis beat sound: higher-pitched bass drum
    private let emphasisBeatFrequency: Float = 120.0 // Hz - one octave above bass drum
    private let emphasisBeatDuration: Double = 0.08 // 80ms - same as bass drum
    private let emphasisBeatAmplitude: Float = 1.2 // Slightly louder than regular beat
    private var emphasisBeatBuffer: AVAudioPCMBuffer?

    // Volume control
    private var currentVolume: Float = 0.0 // Metronome volume: 0.0 = silent, 1.0 = max
    private var masterVolume: Float = 1.0 // Master volume for voice: 0.0 = silent, 1.0 = max
    private var beatVolume: Float = 10.0 // Beat volume multiplier: 0.0 = silent, up to 30.0 = 30x boost

    private var currentBPM: Int = 0
    private var beatBuffer: AVAudioPCMBuffer?
    private var silentBuffer: AVAudioPCMBuffer? // Silent buffer for timing when beats disabled

    // Beat counting for emphasis
    private var beatCounter: Int = 0
    private var emphasisBeatEnabled: Bool = false
    private var emphasisBeatInterval: Int = 2 // Every Nth beat
    private var audioBeatsEnabled: Bool = true

    // Voice alert throttling
    private var lastAlertTime: Date?
    private let alertThrottleInterval: TimeInterval = 30.0 // seconds

    // Important alert queue
    private var pendingImportantAlerts: [String] = []
    private var isProcessingImportantAlert = false

    // MARK: - Setup

    func setup() throws {
        // Configure audio session
        try configureAudioSession()

        // Create audio engine
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        // Connect player to main mixer
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Create speech synthesizer
        let synthesizer = AVSpeechSynthesizer()

        // Store references
        self.audioEngine = engine
        self.playerNode = player
        self.speechSynthesizer = synthesizer

        // Generate beat buffers (reused for all beats)
        self.beatBuffer = try generateBeatBuffer(format: format)
        self.emphasisBeatBuffer = try generateEmphasisBeatBuffer(format: format)
        self.silentBuffer = try generateSilentBuffer(format: format)
    }

    func teardown() {
        stopTempoBeats()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        speechSynthesizer = nil
        beatBuffer = nil
        emphasisBeatBuffer = nil
        silentBuffer = nil
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Configure for playback with mixing. Some simulator/device combos
        // do not support `.longFormAudio`, so fall back to the default policy.
        do {
            try audioSession.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: [.mixWithOthers, .duckOthers]
            )
        } catch {
            print("AudioEngine: Falling back to default audio policy: \(error)")
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
        }

        try audioSession.setActive(true)
    }

    // MARK: - Emphasis Beat Configuration

    /// Configures emphasis beat settings
    func configureEmphasisBeat(enabled: Bool, interval: Int, audioBeatsEnabled: Bool) {
        self.emphasisBeatEnabled = enabled
        self.emphasisBeatInterval = interval
        self.audioBeatsEnabled = audioBeatsEnabled
    }

    // MARK: - Tempo Beats

    func startTempoBeats(bpm: Int) throws {
        guard let engine = audioEngine,
              let player = playerNode,
              let buffer = beatBuffer else {
            throw AudioEngineError.notSetup
        }

        // Stop if already playing
        if isPlaying {
            stopTempoBeats()
        }

        currentBPM = bpm
        beatCounter = 0 // Reset beat counter

        // Start engine if needed
        if !engine.isRunning {
            try engine.start()
        }

        // Start player
        player.play()

        // Schedule initial beats
        scheduleBeats(player: player, buffer: buffer, bpm: bpm, count: 10)

        isPlaying = true
    }

    func stopTempoBeats() {
        guard let player = playerNode else {
            isPlaying = false
            return
        }

        if isPlaying && player.isPlaying {
            // Use reset instead of stop to avoid deadlocks
            player.reset()
        }

        isPlaying = false
    }

    func updateTempo(bpm: Int) throws {
        currentBPM = bpm
        guard isPlaying else { return }

        // Restart with new BPM
        try startTempoBeats(bpm: bpm)
    }

    // MARK: - Beat Scheduling

    /// Returns the appropriate buffer for the current beat based on settings
    private func bufferForBeat() -> AVAudioPCMBuffer? {
        beatCounter += 1

        // Check if this is an emphasis beat
        let isEmphasisBeat = emphasisBeatEnabled && (beatCounter % emphasisBeatInterval == 0)

        if isEmphasisBeat {
            // Play emphasis beat
            return emphasisBeatBuffer
        } else if audioBeatsEnabled {
            // Play regular beat
            return beatBuffer
        } else {
            // Neither - return nil (silence)
            return nil
        }
    }

    private func scheduleBeats(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, bpm: Int, count: Int) {
        // Calculate samples per beat
        let samplesPerBeat = AVAudioFramePosition(sampleRate * 60.0 / Double(bpm))

        // Get current player time
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            // Not playing yet, schedule at nil (immediate)
            for i in 0..<count {
                let isLastBeat = (i == count - 1)
                let beatBuffer = bufferForBeat()

                if isLastBeat {
                    // Use the beat buffer if available, otherwise use silent buffer for timing
                    let bufferToSchedule = beatBuffer ?? silentBuffer ?? buffer
                    player.scheduleBuffer(bufferToSchedule, at: nil, options: []) { [weak self] in
                        self?.scheduleNextBeat(player: player, buffer: buffer, bpm: bpm)
                    }
                } else {
                    if let buf = beatBuffer {
                        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
                    }
                    // If nil, skip this beat (silence)
                }
            }
            return
        }

        // Schedule beats at precise sample times
        var sampleTime = playerTime.sampleTime

        for i in 0..<count {
            sampleTime += samplesPerBeat

            let time = AVAudioTime(
                sampleTime: sampleTime,
                atRate: sampleRate
            )

            let beatBuffer = bufferForBeat()

            let isLastBeat = (i == count - 1)
            if isLastBeat {
                // Use the beat buffer if available, otherwise use silent buffer for timing
                let bufferToSchedule = beatBuffer ?? silentBuffer ?? buffer
                player.scheduleBuffer(bufferToSchedule, at: time, options: []) { [weak self] in
                    self?.scheduleNextBeat(player: player, buffer: buffer, bpm: bpm)
                }
            } else {
                if let buf = beatBuffer {
                    player.scheduleBuffer(buf, at: time, options: [], completionHandler: nil)
                }
                // If nil, skip this beat (silence)
            }
        }
    }

    private func scheduleNextBeat(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, bpm: Int) {
        guard isPlaying, currentBPM == bpm else { return }

        // Schedule one more beat to maintain continuous playback
        scheduleBeats(player: player, buffer: buffer, bpm: bpm, count: 1)
    }

    // MARK: - Beat Buffer Generation

    private func generateBeatBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * beatDuration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioEngineError.bufferCreationFailed
        }

        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioEngineError.bufferCreationFailed
        }

        // Generate bass drum sound
        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * Float.pi * currentBeatFrequency * Float(frame) / Float(sampleRate)
            let envelope = envelopeValue(frame: frame, totalFrames: Int(frameCount))
            channelData[frame] = beatAmplitude * sin(phase) * envelope
        }

        return buffer
    }

    private func envelopeValue(frame: Int, totalFrames: Int) -> Float {
        // Bass drum envelope: quick attack, exponential decay, smooth fade-out
        // This gives a punchy "thump" sound without click at the end
        let attackFrames = totalFrames / 20 // 5% attack (very quick)
        let fadeOutFrames = totalFrames / 10 // 10% fade-out at end to avoid click
        let fadeOutStart = totalFrames - fadeOutFrames

        if frame < attackFrames {
            // Quick attack ramp up
            return Float(frame) / Float(attackFrames)
        } else if frame >= fadeOutStart {
            // Final fade-out: multiply exponential decay by linear fade to zero
            let decayProgress = (Float(frame) - Float(attackFrames)) / Float(totalFrames - attackFrames)
            let expDecay = exp(-4.0 * decayProgress)
            // Linear fade from 1.0 to 0.0 over the fade-out region
            let fadeProgress = Float(frame - fadeOutStart) / Float(fadeOutFrames)
            let linearFade = 1.0 - fadeProgress
            return expDecay * linearFade
        } else {
            // Exponential decay for punchy bass drum sound
            let decayProgress = (Float(frame) - Float(attackFrames)) / Float(totalFrames - attackFrames)
            return exp(-4.0 * decayProgress)
        }
    }

    /// Creates an emphasis beat buffer with a distinct snappy click sound
    private func generateEmphasisBeatBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * emphasisBeatDuration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioEngineError.bufferCreationFailed
        }

        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioEngineError.bufferCreationFailed
        }

        // Generate snappy click sound (higher amplitude for prominence)
        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * Float.pi * emphasisBeatFrequency * Float(frame) / Float(sampleRate)
            let envelope = emphasisEnvelopeValue(frame: frame, totalFrames: Int(frameCount))
            channelData[frame] = emphasisBeatAmplitude * sin(phase) * envelope
        }

        return buffer
    }

    /// Creates a silent buffer for timing purposes when beats are disabled
    private func generateSilentBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * beatDuration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioEngineError.bufferCreationFailed
        }

        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioEngineError.bufferCreationFailed
        }

        // Fill with zeros (silence)
        for i in 0..<Int(frameCount) {
            channelData[i] = 0.0
        }

        return buffer
    }

    /// Envelope for emphasis beat - same as bass drum envelope
    private func emphasisEnvelopeValue(frame: Int, totalFrames: Int) -> Float {
        // Use identical envelope to bass drum for consistent sound character
        let attackFrames = totalFrames / 20 // 5% attack (very quick)
        let fadeOutFrames = totalFrames / 10 // 10% fade-out at end to avoid click
        let fadeOutStart = totalFrames - fadeOutFrames

        if frame < attackFrames {
            // Quick attack ramp up
            return Float(frame) / Float(attackFrames)
        } else if frame >= fadeOutStart {
            // Final fade-out: multiply exponential decay by linear fade to zero
            let decayProgress = (Float(frame) - Float(attackFrames)) / Float(totalFrames - attackFrames)
            let expDecay = exp(-4.0 * decayProgress)
            let fadeProgress = Float(frame - fadeOutStart) / Float(fadeOutFrames)
            let linearFade = 1.0 - fadeProgress
            return expDecay * linearFade
        } else {
            // Exponential decay for punchy sound
            let decayProgress = (Float(frame) - Float(attackFrames)) / Float(totalFrames - attackFrames)
            return exp(-4.0 * decayProgress)
        }
    }

    // MARK: - Volume Control

    /// Sets the metronome volume
    /// - Parameter volume: 0.0 (silent) to 1.0 (max)
    func setMetronomeVolume(_ volume: Float) {
        currentVolume = max(0.0, min(1.0, volume))
        updatePlayerVolume()
    }

    /// Sets the master volume for all audio output (voice alerts)
    /// - Parameter volume: 0.0 (silent) to 1.0 (max)
    func setMasterVolume(_ volume: Float) {
        masterVolume = max(0.0, min(1.0, volume))
        updateSpeechVolume()
    }

    /// Sets the beat volume multiplier (gain boost for metronome/debug sounds)
    /// - Parameter volume: 0.0 (silent) to 30.0 (30x boost)
    func setBeatVolume(_ volume: Float) {
        beatVolume = max(0.0, min(30.0, volume))
        updatePlayerVolume()
    }

    /// Updates the player node volume (metronome volume * beatVolume)
    /// Beat volume can exceed 1.0 for gain boost
    private func updatePlayerVolume() {
        // Apply beat volume as a multiplier (can boost up to 30x)
        // currentVolume is 0-1 (on/off control), beatVolume is the gain
        playerNode?.volume = min(currentVolume * beatVolume, 30.0)
    }

    /// Updates the speech synthesizer volume
    private func updateSpeechVolume() {
        // AVSpeechSynthesizer doesn't have a direct volume property
        // Volume will be applied per-utterance in playVoiceAlert
    }

    /// Calculates and sets volume based on pace deviation
    /// - Parameters:
    ///   - deviationSeconds: How many seconds off target pace (absolute value)
    ///   - toleranceSeconds: Tolerance before metronome starts (e.g., 5 seconds)
    ///   - maxDeviationSeconds: Deviation at which volume reaches max (e.g., 30 seconds)
    ///   - minVolume: Volume when barely outside tolerance
    ///   - maxVolume: Volume when at or beyond max deviation
    func updateVolumeForDeviation(
        deviationSeconds: Int,
        toleranceSeconds: Int = 5,
        maxDeviationSeconds: Int = 30,
        minVolume: Float = 0.3,
        maxVolume: Float = 1.0
    ) {
        if deviationSeconds <= toleranceSeconds {
            // Within tolerance - silent
            setMetronomeVolume(0.0)
        } else {
            // Outside tolerance - volume scales from minVolume to maxVolume
            let excessDeviation = Float(deviationSeconds - toleranceSeconds)
            let maxExcess = Float(maxDeviationSeconds - toleranceSeconds)
            let normalizedDeviation = min(1.0, excessDeviation / maxExcess)
            // Linear interpolation between minVolume and maxVolume
            let volume = minVolume + normalizedDeviation * (maxVolume - minVolume)
            setMetronomeVolume(volume)
        }
    }

    /// Updates beat frequency based on pace direction
    /// - Parameter isTooSlow: true = higher pitch (encourage speed up), false = lower pitch (encourage slow down)
    func updateBeatFrequency(isTooSlow: Bool) {
        // Higher pitch when too slow (urgency to speed up)
        // Lower pitch when too fast (calm down signal)
        let newFrequency = isTooSlow ? highBeatFrequency : lowBeatFrequency

        // Only regenerate if frequency changed
        guard newFrequency != currentBeatFrequency else { return }

        currentBeatFrequency = newFrequency

        // Regenerate beat buffer with new frequency
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }

        do {
            beatBuffer = try generateBeatBuffer(format: format)
        } catch {
            print("AudioEngine: Failed to regenerate beat buffer: \(error)")
        }
    }

    // MARK: - Debug Sounds

    func playDebugSound() {
        // Play a short woodblock click using AVAudioPlayerNode
        guard let player = playerNode else { return }

        // Generate a short click sound (woodblock-like)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(sampleRate * 0.05) // 50ms click
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = frameCount

        // Generate woodblock click: short burst at higher frequency
        // Apply beatVolume for gain boost (can go up to 30x)
        let clickFrequency: Float = 1200.0
        let effectiveVolume = min(beatVolume, 30.0) // Cap at 30x
        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * Float.pi * clickFrequency * Float(frame) / Float(sampleRate)
            let envelope = exp(-15.0 * Float(frame) / Float(frameCount)) // Fast decay
            channelData[frame] = 0.5 * sin(phase) * envelope * effectiveVolume
        }

        // Schedule and play immediately (don't interfere with metronome)
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    func playDebugSoundsStartup() {
        // Play 3 clicks with 200ms spacing to confirm audio is working
        playDebugSound()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.playDebugSound()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.playDebugSound()
        }
    }

    // MARK: - Voice Alerts

    func playVoiceAlert(_ message: String) {
        guard let synthesizer = speechSynthesizer else { return }

        // Throttle alerts
        if let lastTime = lastAlertTime,
           Date().timeIntervalSince(lastTime) < alertThrottleInterval {
            return
        }

        lastAlertTime = Date()

        // Create utterance
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1 // Slightly faster
        utterance.volume = masterVolume // Apply master volume
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        // Speak
        synthesizer.speak(utterance)
    }

    // MARK: - Important Alerts (bypasses throttle, queues if speaking)

    func playImportantAlert(_ message: String) {
        // Add to queue
        pendingImportantAlerts.append(message)

        // Process queue if not already processing
        processImportantAlertQueue()
    }

    private func processImportantAlertQueue() {
        guard !isProcessingImportantAlert,
              !pendingImportantAlerts.isEmpty else {
            return
        }

        // Check if currently speaking - wait and retry
        if isSpeaking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.processImportantAlertQueue()
            }
            return
        }

        isProcessingImportantAlert = true
        let message = pendingImportantAlerts.removeFirst()

        guard let synthesizer = speechSynthesizer else {
            isProcessingImportantAlert = false
            return
        }

        // Create utterance (no throttle check)
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.volume = masterVolume
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        // Speak
        synthesizer.speak(utterance)

        // Schedule check for when speech is done to process next item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isProcessingImportantAlert = false
            self?.processImportantAlertQueue()
        }
    }

    // MARK: - Errors

    enum AudioEngineError: Error {
        case notSetup
        case bufferCreationFailed
    }
}
