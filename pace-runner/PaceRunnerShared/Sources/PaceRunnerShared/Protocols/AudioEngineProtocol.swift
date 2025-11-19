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

    /// Cleanup audio resources
    func teardown()
}
