import Foundation

/// Configuration for beat sounds used by the audio engine
///
/// Allows customization of regular metronome beats and emphasis beats.
/// Sound profiles can be swapped at runtime to change the audio character.
public struct BeatSoundProfile: Codable, Equatable, Sendable {
    public let name: String
    public let regularBeat: BeatSound
    public let emphasisBeat: BeatSound

    public init(name: String, regularBeat: BeatSound, emphasisBeat: BeatSound) {
        self.name = name
        self.regularBeat = regularBeat
        self.emphasisBeat = emphasisBeat
    }

    /// Configuration for a single beat sound
    public struct BeatSound: Codable, Equatable, Sendable {
        /// Frequency in Hz (e.g., 60 for bass drum, 120 for higher pitch)
        public let frequency: Float

        /// Duration in seconds (e.g., 0.08 for 80ms)
        public let duration: Double

        /// Amplitude multiplier (1.0 = normal, 1.2 = 20% louder)
        public let amplitude: Float

        /// Exponential decay rate (higher = faster decay, e.g., 4.0 for punchy sound)
        public let decayRate: Float

        public init(frequency: Float, duration: Double, amplitude: Float, decayRate: Float) {
            self.frequency = frequency
            self.duration = duration
            self.amplitude = amplitude
            self.decayRate = decayRate
        }
    }

    // MARK: - Built-in Profiles

    /// Standard profile: bass drum at 60Hz with higher-pitched emphasis at 120Hz
    public static let standard = BeatSoundProfile(
        name: "Standard",
        regularBeat: BeatSound(
            frequency: 60.0,    // Low bass drum
            duration: 0.08,     // 80ms
            amplitude: 1.0,
            decayRate: 4.0
        ),
        emphasisBeat: BeatSound(
            frequency: 120.0,   // One octave higher
            duration: 0.08,     // Same duration
            amplitude: 1.2,     // Slightly louder
            decayRate: 4.0      // Same decay character
        )
    )
}
