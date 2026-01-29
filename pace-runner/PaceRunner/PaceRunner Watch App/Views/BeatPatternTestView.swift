import SwiftUI
import AVFoundation
import PaceRunnerShared

/// Debug view for testing beat patterns on physical watch
/// Cycles through metronome only, metronome + emphasis (2/4/8), and emphasis only (2/4/8)
/// Announces each pattern before playing
struct BeatPatternTestView: View {
    @State private var isRunning = false
    @State private var currentPatternIndex = 0
    @State private var audioEngine: AudioEngine?
    @State private var patternTimer: Timer?
    @State private var countdown: Int = 0

    private let patternDuration: TimeInterval = 12.0 // seconds per pattern
    private let bpm = 120 // 2 beats per second for clear feedback

    // Define all test patterns
    private let patterns: [(name: String, announcement: String, metronome: Bool, emphasis: Bool, interval: Int)] = [
        ("Metronome Only", "Metronome only, no emphasis", true, false, 2),
        ("Metro + Emphasis 2", "Metronome with emphasis every second beat", true, true, 2),
        ("Metro + Emphasis 4", "Metronome with emphasis every fourth beat", true, true, 4),
        ("Metro + Emphasis 8", "Metronome with emphasis every eighth beat", true, true, 8),
        ("Emphasis Only 2", "Emphasis only, every second beat, no metronome", false, true, 2),
        ("Emphasis Only 4", "Emphasis only, every fourth beat", false, true, 4),
        ("Emphasis Only 8", "Emphasis only, every eighth beat", false, true, 8),
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("Beat Pattern Test")
                .font(.headline)

            if isRunning {
                Text(patterns[currentPatternIndex].name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.blue)
                    .multilineTextAlignment(.center)

                Text("\(countdown)s")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)

                Text("Pattern \(currentPatternIndex + 1) of \(patterns.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Stop") {
                    stopTest()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Text("Tests all beat patterns:\nMetronome, Emphasis combos")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Start Test") {
                    startTest()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onDisappear {
            stopTest()
        }
    }

    private func startTest() {
        // Setup audio engine
        let engine = AudioEngine()
        do {
            try engine.setup()
            engine.setMasterVolume(1.0)
            engine.setBeatVolume(10.0) // Medium volume
            engine.setMetronomeVolume(1.0)
            audioEngine = engine
            isRunning = true
            currentPatternIndex = 0

            // Start first pattern
            playCurrentPattern()

        } catch {
            print("BeatPatternTestView: Failed to setup audio: \(error)")
        }
    }

    private func stopTest() {
        patternTimer?.invalidate()
        patternTimer = nil
        audioEngine?.stopTempoBeats()
        audioEngine?.teardown()
        audioEngine = nil
        isRunning = false
        currentPatternIndex = 0
        countdown = 0
    }

    private func playCurrentPattern() {
        guard let engine = audioEngine, currentPatternIndex < patterns.count else {
            // All patterns complete, stop
            stopTest()
            return
        }

        let pattern = patterns[currentPatternIndex]

        // Stop current beats
        engine.stopTempoBeats()

        // Announce the pattern
        engine.playImportantAlert(pattern.announcement)

        // Wait for announcement to finish, then start beats
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            guard isRunning else { return }

            // Configure emphasis beat settings
            engine.configureEmphasisBeat(
                enabled: pattern.emphasis,
                interval: pattern.interval,
                audioBeatsEnabled: pattern.metronome
            )

            // Start beats
            do {
                try engine.startTempoBeats(bpm: bpm)
            } catch {
                print("BeatPatternTestView: Failed to start beats: \(error)")
            }

            // Start countdown
            countdown = Int(patternDuration)
            startCountdown()
        }
    }

    private func startCountdown() {
        patternTimer?.invalidate()
        patternTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            countdown -= 1
            if countdown <= 0 {
                patternTimer?.invalidate()
                patternTimer = nil
                advanceToNextPattern()
            }
        }
    }

    private func advanceToNextPattern() {
        currentPatternIndex += 1
        if currentPatternIndex < patterns.count {
            playCurrentPattern()
        } else {
            // All done - announce completion
            audioEngine?.stopTempoBeats()
            audioEngine?.playImportantAlert("Beat pattern test complete")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                stopTest()
            }
        }
    }
}

#Preview {
    BeatPatternTestView()
}
