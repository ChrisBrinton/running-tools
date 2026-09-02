import XCTest
@testable import PaceRunnerShared

/// Tests for the neutral-sounding metronome during the demonstration hold.
///
/// Reported from a run: at the start of a run and at the start of a sharply
/// different segment the metronome "fires with an opinion". The directional
/// path is gated by the neutral hold, so the culprit was emphasis mode 0 —
/// which is not neutral to the ear, it still plays the distinct emphasis tone.
/// While the beat is demonstrating footfall rhythm rather than encouraging a
/// pace change, every beat must sound the same.
final class EmphasisBeatSuppressionTests: XCTestCase {

    private typealias Selection = AudioEngine.BeatSelection

    private func select(
        counter: Int,
        suppressed: Bool,
        beatMode: Int = 0,
        emphasisEnabled: Bool = true,
        emphasisInterval: Int = 2,
        audioBeatsEnabled: Bool = true
    ) -> Selection {
        AudioEngine.selectBeat(
            counter: counter,
            emphasisEnabled: emphasisEnabled,
            emphasisInterval: emphasisInterval,
            emphasisSuppressed: suppressed,
            beatMode: beatMode,
            audioBeatsEnabled: audioBeatsEnabled
        )
    }

    // MARK: - Suppressed: demonstrating footfalls

    /// The core fix: while suppressed, no beat may carry an opinion, no matter
    /// what direction the pace logic last asked for.
    func testSuppressedSlotsNeverSoundDirectional() {
        for beatMode in [-1, 0, 1] {
            for counter in 1...8 {
                let selection = select(counter: counter, suppressed: true, beatMode: beatMode)
                XCTAssertEqual(selection, .regular,
                               "counter \(counter), mode \(beatMode) should demonstrate, not direct")
            }
        }
    }

    /// Suppression changes the tone, not the rhythm — the accent slot still
    /// sounds, so the runner keeps hearing a steady beat to match.
    func testSuppressedEmphasisSlotStillSounds() {
        XCTAssertEqual(select(counter: 2, suppressed: true), .regular)
        XCTAssertNotEqual(select(counter: 2, suppressed: true), .silent)
    }

    /// The dangerous config: accents on, regular beats off. Here the emphasis
    /// slot is the only audible beat, so suppressing it must not go silent.
    func testAccentOnlyConfigStaysAudibleWhileSuppressed() {
        XCTAssertEqual(select(counter: 2, suppressed: true, audioBeatsEnabled: false), .regular,
                       "The only audible beat must survive the neutral hold")
        XCTAssertEqual(select(counter: 1, suppressed: true, audioBeatsEnabled: false), .silent,
                       "Non-accent slots stay silent in this config, as before")
    }

    // MARK: - Not suppressed: directing pace

    func testUnsuppressedEmphasisCarriesDirection() {
        XCTAssertEqual(select(counter: 2, suppressed: false, beatMode: 1), .upbeat)
        XCTAssertEqual(select(counter: 2, suppressed: false, beatMode: -1), .downbeat)
        XCTAssertEqual(select(counter: 2, suppressed: false, beatMode: 0), .emphasis)
    }

    /// Mode 0 is a distinct accent, not a neutral beat — the reason suppression
    /// had to be added rather than relying on mode 0.
    func testModeZeroIsStillAnAccentNotARegularBeat() {
        XCTAssertEqual(select(counter: 2, suppressed: false, beatMode: 0), .emphasis)
        XCTAssertNotEqual(select(counter: 2, suppressed: false, beatMode: 0), .regular)
    }

    func testNonEmphasisSlotsAreUnaffectedBySuppression() {
        XCTAssertEqual(select(counter: 1, suppressed: false), .regular)
        XCTAssertEqual(select(counter: 1, suppressed: true), .regular)
        XCTAssertEqual(select(counter: 3, suppressed: false, beatMode: 1), .regular,
                       "Direction only ever rides on emphasis slots")
    }

    // MARK: - Settings interaction

    func testEmphasisDisabledIgnoresSuppressionEntirely() {
        for counter in 1...4 {
            XCTAssertEqual(select(counter: counter, suppressed: true, emphasisEnabled: false), .regular)
            XCTAssertEqual(select(counter: counter, suppressed: false, emphasisEnabled: false), .regular)
        }
    }

    func testAllAudioDisabledStaysSilent() {
        let selection = select(counter: 1, suppressed: true,
                               emphasisEnabled: false, audioBeatsEnabled: false)
        XCTAssertEqual(selection, .silent)
    }

    func testEmphasisIntervalIsHonored() {
        // Interval 4: only every 4th beat is an accent slot.
        XCTAssertEqual(select(counter: 4, suppressed: false, beatMode: 1, emphasisInterval: 4), .upbeat)
        for counter in [1, 2, 3, 5] {
            XCTAssertEqual(select(counter: counter, suppressed: false, beatMode: 1, emphasisInterval: 4),
                           .regular, "counter \(counter) is not an accent slot at interval 4")
        }
    }

    /// A zero interval would trap `counter % interval` in a division by zero.
    func testZeroIntervalDoesNotCrash() {
        XCTAssertEqual(select(counter: 1, suppressed: false, emphasisInterval: 0), .regular)
    }
}
