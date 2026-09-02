import XCTest
import AVFoundation
@testable import PaceRunnerShared

/// Tests for spoken pace announcements and audio interruption recovery.
///
/// Both cover bugs reported from real runs:
/// - Voice callouts said "nine o'clock" instead of "nine minutes per mile".
/// - Recording a voice memo mid-run killed the drum beats permanently.
final class PaceSpokenTests: XCTestCase {

    // MARK: - Pace.spoken

    /// A whole-minute pace must not be spoken as a clock time.
    /// "9:00" is what AVSpeechSynthesizer reads as "nine o'clock".
    func testWholeMinutePaceSpellsOutUnits() {
        let pace = Pace(minutes: 9, seconds: 0)

        XCTAssertEqual(pace.spoken, "9 minutes per mile")
        XCTAssertFalse(pace.spoken.contains(":"),
                       "A colon makes AVSpeechSynthesizer read the pace as a clock time")
    }

    func testPaceWithSecondsSpellsOutBothUnits() {
        XCTAssertEqual(Pace(minutes: 8, seconds: 42).spoken, "8 minutes 42 seconds per mile")
        XCTAssertEqual(Pace(minutes: 7, seconds: 5).spoken, "7 minutes 5 seconds per mile")
    }

    func testSingleSecondUsesSingularUnit() {
        XCTAssertEqual(Pace(minutes: 10, seconds: 1).spoken, "10 minutes 1 second per mile")
    }

    /// The display form is unchanged — only spoken strings switched over.
    func testFormattedIsStillTheDisplayForm() {
        XCTAssertEqual(Pace(minutes: 9, seconds: 0).formatted, "9:00")
        XCTAssertEqual(Pace(minutes: 7, seconds: 5).formatted, "7:05")
    }

    /// No pace across the supported range may render a colon in its spoken form.
    func testNoSpokenPaceContainsAColon() {
        for totalSeconds in 240...1200 {
            guard let pace = Pace(totalSeconds: totalSeconds) else {
                XCTFail("Pace(totalSeconds: \(totalSeconds)) should be valid")
                continue
            }
            XCTAssertFalse(pace.spoken.contains(":"),
                           "\(pace.formatted) produced a colon in its spoken form")
        }
    }

    // MARK: - Interruption recovery

    /// An interruption must stop beat generation, since the system has already
    /// stopped AVAudioEngine — leaving isPlaying true is what hid the failure.
    func testInterruptionBeganStopsBeatGeneration() {
        let engine = AudioEngine()
        engine.setTestState(bpm: 170, playing: true)
        XCTAssertTrue(engine.isPlaying)

        engine.handleInterruptionBegan()

        XCTAssertFalse(engine.isPlaying,
                       "Beats must stop generating into an engine the system has stopped")
    }

    /// An explicit stop must not be undone by the recovery watchdog. Interruption
    /// state is private, so this asserts the observable outcome: an interruption
    /// followed by a stop leaves playback stopped.
    func testExplicitStopSurvivesAnEarlierInterruption() {
        let engine = AudioEngine()
        engine.setTestState(bpm: 170, playing: true)

        engine.handleInterruptionBegan()
        engine.stopTempoBeats()
        engine.handleInterruptionEnded(systemSuggestsResume: true)

        XCTAssertFalse(engine.isPlaying,
                       "A deliberate stop must not be resurrected by interruption recovery")
    }

    /// Recovery must not resume beats that were never playing.
    func testInterruptionWhileStoppedLeavesPlaybackStopped() {
        let engine = AudioEngine()
        engine.setTestState(bpm: 0, playing: false)

        engine.handleInterruptionBegan()
        engine.handleInterruptionEnded(systemSuggestsResume: true)

        XCTAssertFalse(engine.isPlaying)
    }
}
