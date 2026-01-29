import Foundation
import AVFoundation

/// Protocol for audio tempo beats and voice alerts
///
/// AudioEngine generates:
/// - Tempo beats: Sample-accurate metronome clicks at target cadence
/// - Voice alerts: TTS announcements for mile markers and pace deviations
///
/// Constitution: ±5ms timing accuracy, minimal CPU for battery efficiency
public protocol AudioEngineProtocol: AnyObject {
    /// Whether audio is currently playing
    var isPlaying: Bool { get }

    /// Configure audio session and engine
    func setup() throws

    /// Start tempo beats at specified BPM
    /// - Parameter bpm: Beats per minute (cadence)
    func startTempoBeats(bpm: Int) throws

    /// Stop tempo beats
    func stopTempoBeats()

    /// Play voice alert
    /// - Parameter message: Text to speak
    func playVoiceAlert(_ message: String)

    /// Update tempo to new BPM
    /// - Parameter bpm: New beats per minute
    func updateTempo(bpm: Int) throws

    /// Sets the metronome volume
    /// - Parameter volume: 0.0 (silent) to 1.0 (max)
    func setMetronomeVolume(_ volume: Float)

    /// Sets the master volume for all audio output
    /// - Parameter volume: 0.0 (silent) to 1.0 (max)
    func setMasterVolume(_ volume: Float)

    /// Sets the beat volume multiplier (gain boost for metronome/debug sounds)
    /// - Parameter volume: 0.0 (silent) to 30.0 (30x boost)
    func setBeatVolume(_ volume: Float)

    /// Updates volume based on pace deviation (adaptive metronome)
    /// - Parameters:
    ///   - deviationSeconds: Absolute deviation from target pace in seconds
    ///   - toleranceSeconds: Tolerance before metronome starts playing
    ///   - maxDeviationSeconds: Deviation at which volume reaches maximum
    ///   - minVolume: Minimum volume when barely outside tolerance (0.0-1.0)
    ///   - maxVolume: Maximum volume when far off pace (0.0-1.0)
    func updateVolumeForDeviation(
        deviationSeconds: Int,
        toleranceSeconds: Int,
        maxDeviationSeconds: Int,
        minVolume: Float,
        maxVolume: Float
    )

    /// Updates beat frequency based on pace direction
    /// - Parameter isTooSlow: true = higher pitch (encourage speed up), false = lower pitch (encourage slow down)
    func updateBeatFrequency(isTooSlow: Bool)

    /// Configures emphasis beat settings
    /// - Parameters:
    ///   - enabled: Whether emphasis beats are enabled
    ///   - interval: Play emphasis beat every Nth beat (2, 4, or 8)
    ///   - audioBeatsEnabled: Whether regular metronome beats are enabled
    func configureEmphasisBeat(enabled: Bool, interval: Int, audioBeatsEnabled: Bool)

    /// Configures the sound profile for beat generation
    /// - Parameter profile: The sound profile to use for regular and emphasis beats
    func configureSoundProfile(_ profile: BeatSoundProfile)

    /// Plays a debug sound (woodblock) for GPS filtering feedback
    func playDebugSound()

    /// Plays 3 debug sounds at startup to confirm audio is working
    func playDebugSoundsStartup()

    /// Whether voice synthesis is currently speaking
    var isSpeaking: Bool { get }

    /// Play an important voice alert that bypasses throttling
    /// Used for mile markers and workout completion announcements
    /// Will queue if speech is already playing
    /// - Parameter message: Text to speak
    func playImportantAlert(_ message: String)

    /// Cleanup audio resources
    func teardown()
}
