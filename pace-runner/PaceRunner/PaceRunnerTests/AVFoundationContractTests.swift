import XCTest
import AVFoundation

final class AVFoundationContractTests: XCTestCase {

    func testAudioEngineConfiguration() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44_100,
                                   channels: 1,
                                   interleaved: false)
        XCTAssertNotNil(format)

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()

        XCTAssertFalse(engine.isRunning)
    }

    func testBufferCreation() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frameCount: AVAudioFrameCount = 441
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        XCTAssertNotNil(buffer)
    }
}
