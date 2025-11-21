import XCTest
@testable import PaceRunner_Watch_App

final class AudioHelpersTests: XCTestCase {
    func testGenerateBeatSamplesBounded() {
        let samples = AudioEngine.generateBeatSamples(
            sampleRate: 44_100,
            duration: 0.01,
            frequency: 800,
            amplitude: 0.3
        )

        XCTAssertEqual(samples.count, Int(44_100 * 0.01))
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 0.3 })
    }
}
