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
    private var emphasisBeatSamples: [Float] = []      // Normal emphasis (on-pace)
    private var emphasisUpbeatSamples: [Float] = []    // Higher pitch emphasis (speed up)
    private var emphasisDownbeatSamples: [Float] = []  // Lower pitch emphasis (slow down)

    /// Current emphasis beat mode: 0=normal, 1=upbeat (speed up), -1=downbeat (slow down)
    private var emphasisBeatMode: Int = 0

    /// When true, emphasis slots sound with the REGULAR beat tone.
    ///
    /// Mode 0 is not neutral to the ear — it still plays the distinct
    /// `emphasisBeat` tone, which reads as an opinion. While the metronome is
    /// demonstrating footfall rhythm rather than directing pace (run start, and
    /// the start of a segment whose pace differs sharply), every beat must sound
    /// the same.
    private var emphasisBeatsSuppressed: Bool = false

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

    // MARK: Interruption recovery state

    /// Block-based observers for session/engine notifications, retained for removal.
    private var sessionObservers: [NSObjectProtocol] = []

    /// Set when an interruption stops beats we were meant to be playing.
    private var shouldResumeBeats: Bool = false

    /// Serial queue for recovery work. Session activation blocks (up to 8s on
    /// watchOS), so it must never run on the main thread or the audio thread.
    private let recoveryQueue = DispatchQueue(label: "com.pacerunner.audioengine.recovery")

    /// Watchdog that catches interruptions whose `.ended` notification never
    /// arrives — a known watchOS behavior that otherwise leaves beats dead
    /// for the rest of the run.
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogInterval: TimeInterval = 2.0

    /// Guards against overlapping recovery attempts: watchOS session activation
    /// can block for up to 8s while the watchdog keeps ticking every 2s.
    private var recoveryInFlight: Bool = false

    /// Set when a rebuild tore the engine down but `setup()` then failed. Without
    /// it a transient activation failure would leave `audioEngine` nil and the
    /// watchdog with nothing to inspect — beats dead for the rest of the run.
    private var rebuildPending: Bool = false

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

        // Upbeat: two octaves above the regular beat (speed up signal)
        emphasisUpbeatSamples = Self.generateBeatSamples(
            sampleRate: activeSampleRate,
            duration: regular.duration,
            frequency: regular.frequency * 4.0,  // Two octaves up from regular
            amplitude: regular.amplitude,
            decayRate: regular.decayRate
        )

        // Downbeat: two octaves below the regular beat (slow down signal)
        emphasisDownbeatSamples = Self.generateBeatSamples(
            sampleRate: activeSampleRate,
            duration: regular.duration,
            frequency: regular.frequency * 0.25,  // Two octaves down from regular
            amplitude: regular.amplitude,
            decayRate: regular.decayRate
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

        // Recover automatically when another app (Voice Memos, a call) takes
        // the session, or when the route/format changes underneath us.
        registerSessionObservers(for: engine)
        startWatchdog()

        print("AudioEngine.setup: complete, engine running")
    }

    public func teardown() {
        print("AudioEngine.teardown: called")
        stateLock.lock()
        rebuildPending = false
        stateLock.unlock()
        stopWatchdog()
        teardownAudioGraph()
    }

    /// Releases the engine graph without stopping the watchdog.
    ///
    /// The rebuild path uses this rather than `teardown()`: stopping the watchdog
    /// there would remove the very thing that retries a rebuild whose `setup()`
    /// failed, leaving the metronome permanently dead.
    private func teardownAudioGraph() {
        removeSessionObservers()
        stopTempoBeats()
        audioEngine?.stop()
        if let source = sourceNode {
            audioEngine?.detach(source)
        }
        audioEngine = nil
        sourceNode = nil
        speechSynthesizer = nil
    }

    deinit {
        removeSessionObservers()
        stopWatchdog()
    }

    // MARK: - Interruption Recovery

    /// Registers observers that detect the session or engine being pulled away.
    ///
    /// Without these, an interruption (recording a voice memo, an incoming call)
    /// stops `AVAudioEngine` permanently: `AVSpeechSynthesizer` re-activates its
    /// own session on the next `speak()`, so voice cues return while the
    /// metronome stays silent for the rest of the workout.
    private func registerSessionObservers(for engine: AVAudioEngine) {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default

        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        sessionObservers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        })

        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            print("AudioEngine: media services were reset — rebuilding")
            self?.flagResumeIfPlaying()
            self?.recoverPlayback(rebuild: true)
        })

        print("AudioEngine: registered \(sessionObservers.count) session observers")
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        sessionObservers.forEach { center.removeObserver($0) }
        sessionObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            return
        }

        switch type {
        case .began:
            handleInterruptionBegan()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            handleInterruptionEnded(systemSuggestsResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    /// Records that beats need resuming and stops generating into a dead engine.
    func handleInterruptionBegan() {
        stateLock.lock()
        let wasPlaying = isPlaying
        shouldResumeBeats = shouldResumeBeats || wasPlaying
        isPlaying = false
        let bpm = currentBPM
        stateLock.unlock()

        print("AudioEngine: interruption began (wasPlaying=\(wasPlaying), bpm=\(bpm))")
    }

    /// Resumes beats after the interrupting app releases the session.
    ///
    /// We resume even when the system omits `.shouldResume`: these beats are a
    /// workout cue the runner is actively following, not background media.
    func handleInterruptionEnded(systemSuggestsResume: Bool) {
        print("AudioEngine: interruption ended (shouldResume=\(systemSuggestsResume))")
        recoverPlayback(rebuild: false)
    }

    private func handleConfigurationChange() {
        let newRate = audioEngine?.mainMixerNode.outputFormat(forBus: 0).sampleRate

        stateLock.lock()
        let knownRate = activeSampleRate
        if isPlaying { shouldResumeBeats = true }
        stateLock.unlock()

        // A changed sample rate invalidates the pre-computed beat samples and the
        // source node's format, so the graph has to be rebuilt rather than restarted.
        let rateChanged = newRate.map { $0 > 0 && abs($0 - knownRate) > 1.0 } ?? false
        print("AudioEngine: configuration change (rate \(knownRate) -> \(newRate ?? -1), rebuild=\(rateChanged))")

        recoverPlayback(rebuild: rateChanged)
    }

    private func flagResumeIfPlaying() {
        stateLock.lock()
        if isPlaying { shouldResumeBeats = true }
        stateLock.unlock()
    }

    /// Re-activates the session, restarts (or rebuilds) the engine, and resumes
    /// beats at the last known BPM. Always runs off the caller's thread.
    private func recoverPlayback(rebuild: Bool) {
        recoveryQueue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            let alreadyRecovering = self.recoveryInFlight
            let resume = self.shouldResumeBeats
            let bpm = self.currentBPM
            if !alreadyRecovering { self.recoveryInFlight = true }
            self.stateLock.unlock()

            guard !alreadyRecovering else { return }

            defer {
                self.stateLock.lock()
                self.recoveryInFlight = false
                self.stateLock.unlock()
            }

            self.stateLock.lock()
            let retryingRebuild = self.rebuildPending
            self.stateLock.unlock()

            // Torn down while the notification was in flight — nothing to restore.
            // A pending rebuild is the exception: the engine is nil precisely
            // because the last rebuild failed, and that is what we are retrying.
            guard self.audioEngine != nil || retryingRebuild else { return }

            do {
                if rebuild || retryingRebuild {
                    if self.audioEngine != nil { self.teardownAudioGraph() }
                    // Tearing down clears the resume flag, so mark the rebuild
                    // as in progress before setup() can throw.
                    self.stateLock.lock()
                    self.rebuildPending = true
                    self.shouldResumeBeats = resume
                    self.stateLock.unlock()

                    try self.setup()

                    self.stateLock.lock()
                    self.rebuildPending = false
                    self.stateLock.unlock()
                } else {
                    try self.configureAudioSession()
                    if let engine = self.audioEngine, !engine.isRunning {
                        try engine.start()
                    }
                }

                if resume && bpm > 0 {
                    try self.startTempoBeats(bpm: bpm)
                    self.stateLock.lock()
                    self.shouldResumeBeats = false
                    self.stateLock.unlock()
                    print("AudioEngine: beats resumed at \(bpm) BPM")
                }
            } catch {
                // Leave shouldResumeBeats (and rebuildPending) set so the
                // watchdog retries on its next tick.
                self.stateLock.lock()
                self.shouldResumeBeats = resume
                self.stateLock.unlock()
                print("AudioEngine: recovery failed: \(error)")
            }
        }
    }

    // MARK: - Playback Watchdog

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: recoveryQueue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            self?.checkPlaybackHealth()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    /// Catches the two ways recovery can be missed: an interruption whose
    /// `.ended` notification never arrives, and a recovery attempt that threw.
    private func checkPlaybackHealth() {
        stateLock.lock()
        let playing = isPlaying
        let resumePending = shouldResumeBeats
        let bpm = currentBPM
        let awaitingRebuild = rebuildPending
        stateLock.unlock()

        if awaitingRebuild {
            print("AudioEngine.watchdog: rebuild still pending — retrying")
            recoverPlayback(rebuild: true)
            return
        }

        guard let engine = audioEngine else { return }

        if playing && !engine.isRunning {
            print("AudioEngine.watchdog: marked playing but engine stopped — recovering")
            flagResumeIfPlaying()
            recoverPlayback(rebuild: false)
            return
        }

        if resumePending && !playing && bpm > 0 {
            print("AudioEngine.watchdog: resume still pending — retrying")
            recoverPlayback(rebuild: false)
        }
    }

    // MARK: - Beat Selection

    /// Which sound a beat slot plays.
    public enum BeatSelection: Equatable {
        case silent
        case regular
        case emphasis
        case upbeat    // directional: speed up
        case downbeat  // directional: slow down
    }

    /// Decides what a beat slot sounds like. Pure so it can be unit-tested and
    /// called from the audio thread.
    /// - Parameters:
    ///   - counter: 1-based index of this beat within the run.
    ///   - emphasisEnabled: User setting for accent beats.
    ///   - emphasisInterval: Accent every Nth beat.
    ///   - emphasisSuppressed: True while demonstrating rhythm rather than directing.
    ///   - beatMode: 1 = speed up, -1 = slow down, 0 = on pace.
    ///   - audioBeatsEnabled: User setting for the regular beats between accents.
    public static func selectBeat(
        counter: Int,
        emphasisEnabled: Bool,
        emphasisInterval: Int,
        emphasisSuppressed: Bool,
        beatMode: Int,
        audioBeatsEnabled: Bool
    ) -> BeatSelection {
        let isEmphasisSlot = emphasisEnabled
            && emphasisInterval > 0
            && counter % emphasisInterval == 0

        if isEmphasisSlot && !emphasisSuppressed {
            switch beatMode {
            case 1:  return .upbeat
            case -1: return .downbeat
            default: return .emphasis
            }
        }

        // A suppressed emphasis slot still sounds — with the regular tone, so the
        // beat demonstrates rhythm without directing. It must stay audible: when
        // `audioBeatsEnabled` is false the emphasis slot is the ONLY beat, and
        // silencing it would leave the whole neutral hold silent.
        if isEmphasisSlot || audioBeatsEnabled {
            return .regular
        }

        return .silent
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
        let upbeatSamples = emphasisUpbeatSamples
        let downbeatSamples = emphasisDownbeatSamples
        let beatMode = emphasisBeatMode
        let emphasisSuppressed = emphasisBeatsSuppressed
        var currentSampleTime = sampleTime
        stateLock.unlock()

        for frame in 0..<Int(frameCount) {
            var sample: Float = 0.0

            if playing && samplesPerBeatLocal > 0 {
                // Check if we should start a new beat
                if currentSampleTime >= nextBeatTime && !inBeat {
                    counter += 1

                    // Determine which beat to play
                    switch Self.selectBeat(
                        counter: counter,
                        emphasisEnabled: emphasisEnabled,
                        emphasisInterval: emphasisInterval,
                        emphasisSuppressed: emphasisSuppressed,
                        beatMode: beatMode,
                        audioBeatsEnabled: beatsEnabled
                    ) {
                    case .upbeat:
                        beatSamples = upbeatSamples     // Too slow — speed up
                        inBeat = true
                        beatPos = 0
                    case .downbeat:
                        beatSamples = downbeatSamples   // Too fast — slow down
                        inBeat = true
                        beatPos = 0
                    case .emphasis:
                        beatSamples = emphasisSamples   // On pace — normal accent
                        inBeat = true
                        beatPos = 0
                    case .regular:
                        beatSamples = regularSamples
                        inBeat = true
                        beatPos = 0
                    case .silent:
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
        #if os(watchOS)
        // Use longFormAudio policy on watchOS to trigger Bluetooth headphone discovery
        // This is what the Music app uses - it actively searches for and routes to
        // connected Bluetooth audio devices instead of playing through the speaker
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [.mixWithOthers])
        } catch {
            print("AudioEngine: Failed to set longFormAudio policy: \(error)")
            // Fall back to simple playback
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }

        // Use watchOS-specific async activation which handles Bluetooth route negotiation
        // We use a semaphore to wait for activation before starting the audio engine,
        // otherwise audio plays through the speaker before Bluetooth is connected
        let semaphore = DispatchSemaphore(value: 0)
        var activationError: Error?

        session.activate(options: []) { activated, error in
            if let error = error {
                print("AudioEngine: watchOS session activation error: \(error)")
                activationError = error
            } else {
                print("AudioEngine: watchOS session activated: \(activated)")
                // Log the current audio route
                let route = AVAudioSession.sharedInstance().currentRoute
                let outputs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
                print("AudioEngine: audio route after activation: \(outputs)")
            }
            semaphore.signal()
        }

        // Wait up to 8 seconds for Bluetooth route negotiation
        let result = semaphore.wait(timeout: .now() + 8.0)
        if result == .timedOut {
            print("AudioEngine: watchOS session activation timed out (8s) — may play through speaker")
        }
        if let error = activationError {
            print("AudioEngine: proceeding despite activation error: \(error)")
        }
        #else
        // iOS: simple playback category
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            print("AudioEngine: Failed to set audio category: \(error)")
            try session.setCategory(.playback)
        }

        try session.setActive(true)
        #endif
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
        shouldResumeBeats = false
        stateLock.unlock()

        print("AudioEngine.startTempoBeats: playing, samplesPerBeat=\(samplesPerBeat)")
    }

    public func stopTempoBeats() {
        stateLock.lock()
        isPlaying = false
        // An explicit stop cancels any pending interruption resume, otherwise the
        // watchdog would restart beats that were deliberately stopped.
        shouldResumeBeats = false
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

    /// Generates a two-tone sample: first half plays freq1, second half plays freq2
    /// Used for ascending (up note) and descending (down note) directional feedback
    public static func generateTwoToneSamples(
        sampleRate: Double,
        duration: Double,
        freq1: Float,
        freq2: Float,
        amplitude: Float,
        decayRate: Float
    ) -> [Float] {
        let totalFrames = Int(sampleRate * duration)
        let halfFrames = totalFrames / 2
        var samples = Array(repeating: Float.zero, count: totalFrames)

        for frame in 0..<totalFrames {
            let freq = frame < halfFrames ? freq1 : freq2
            let localFrame = frame < halfFrames ? frame : frame - halfFrames
            let phase = 2.0 * Float.pi * freq * Float(localFrame) / Float(sampleRate)
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

    /// Reset beat frequency to normal pitch (on-pace)
    public func resetBeatFrequency() {
        guard currentFrequencyRatio != 1.0 else { return }

        stateLock.lock()
        currentFrequencyRatio = 1.0
        regenerateBeatSamples()
        stateLock.unlock()
    }

    /// Set emphasis beat mode for pace direction feedback
    /// - Parameter mode: 1 = upbeat (speed up), -1 = downbeat (slow down), 0 = normal
    /// Suppresses the emphasis tone so every beat sounds identical.
    /// - Parameter suppressed: true while the beat demonstrates rather than directs.
    public func setEmphasisBeatsSuppressed(_ suppressed: Bool) {
        stateLock.lock()
        let changed = emphasisBeatsSuppressed != suppressed
        emphasisBeatsSuppressed = suppressed
        stateLock.unlock()

        if changed {
            print("AudioEngine.setEmphasisBeatsSuppressed: \(suppressed)")
        }
    }

    public func setEmphasisBeatMode(_ mode: Int) {
        stateLock.lock()
        emphasisBeatMode = mode
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
