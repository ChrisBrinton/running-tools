import Foundation
import AVFoundation

/// Audio engine for tempo beats and voice alerts
///
/// Responsibilities:
/// - Generate tempo beats (800Hz sine wave, 10ms duration)
/// - Schedule beats with sample-accurate timing (±5ms)
/// - Synthesize voice alerts via AVSpeechSynthesizer
/// - Mix audio with music from other apps
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

    // Audio format constants
    private let sampleRate: Double = 44100.0
    private let beatFrequency: Float = 800.0 // Hz
    private let beatDuration: Double = 0.01 // 10ms
    private let beatAmplitude: Float = 0.3 // 30% volume

    private var currentBPM: Int = 0
    private var beatBuffer: AVAudioPCMBuffer?

    // Voice alert throttling
    private var lastAlertTime: Date?
    private let alertThrottleInterval: TimeInterval = 30.0 // seconds

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

        // Generate beat buffer (reused for all beats)
        self.beatBuffer = try generateBeatBuffer(format: format)
    }

    func teardown() {
        stopTempoBeats()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        speechSynthesizer = nil
        beatBuffer = nil
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()

        // Configure for playback with mixing
        try audioSession.setCategory(
            .playback,
            mode: .default,
            policy: .longFormAudio, // Enables background audio on watchOS
            options: [.mixWithOthers, .duckOthers]
        )

        try audioSession.setActive(true)
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
        guard let player = playerNode else { return }

        player.stop()
        isPlaying = false
    }

    func updateTempo(bpm: Int) throws {
        guard isPlaying else { return }

        // Restart with new BPM
        try startTempoBeats(bpm: bpm)
    }

    // MARK: - Beat Scheduling

    private func scheduleBeats(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, bpm: Int, count: Int) {
        // Calculate samples per beat
        let samplesPerBeat = AVAudioFramePosition(sampleRate * 60.0 / Double(bpm))

        // Get current player time
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            // Not playing yet, schedule at nil (immediate)
            for _ in 0..<count {
                player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            }
            return
        }

        // Schedule beats at precise sample times
        var sampleTime = playerTime.sampleTime

        for _ in 0..<count {
            sampleTime += samplesPerBeat

            let time = AVAudioTime(
                sampleTime: sampleTime,
                atRate: sampleRate
            )

            player.scheduleBuffer(buffer, at: time, options: []) { [weak self] in
                // When beat plays, schedule next beat (continuous playback)
                self?.scheduleNextBeat(player: player, buffer: buffer, bpm: bpm)
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
        // Calculate frame count for 10ms beat
        let frameCount = AVAudioFrameCount(sampleRate * beatDuration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioEngineError.bufferCreationFailed
        }

        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioEngineError.bufferCreationFailed
        }

        // Generate 800Hz sine wave with envelope
        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * Float.pi * beatFrequency * Float(frame) / Float(sampleRate)
            let envelope = envelopeValue(frame: frame, totalFrames: Int(frameCount))
            channelData[frame] = beatAmplitude * sin(phase) * envelope
        }

        return buffer
    }

    private func envelopeValue(frame: Int, totalFrames: Int) -> Float {
        // Simple linear fade out to prevent clicks
        let fadeFrames = totalFrames / 4 // Fade last 25%
        let fadeStart = totalFrames - fadeFrames

        if frame < fadeStart {
            return 1.0
        } else {
            let fadeProgress = Float(frame - fadeStart) / Float(fadeFrames)
            return 1.0 - fadeProgress
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
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        // Speak
        synthesizer.speak(utterance)
    }

    // MARK: - Errors

    enum AudioEngineError: Error {
        case notSetup
        case bufferCreationFailed
    }
}
