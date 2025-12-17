import SwiftUI
import AVFoundation
import PaceRunnerShared

/// Debug view for testing beat volume on physical watch with AirPods
/// Cycles volume from 0x to max (10x) and back, 1x increase every 15 seconds
struct VolumeTestView: View {
    @State private var isRunning = false
    @State private var currentMultiplier: Float = 0.0
    @State private var isIncreasing = true
    @State private var audioEngine: AudioEngine?
    @State private var cycleTimer: Timer?

    private let maxMultiplier: Float = 30.0
    private let stepSize: Float = 3.0  // 0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30
    private let stepInterval: TimeInterval = 10.0  // Faster cycling for larger range

    var body: some View {
        VStack(spacing: 16) {
            Text("Volume Test")
                .font(.headline)

            Text(String(format: "%.0fx", currentMultiplier))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(colorForMultiplier(currentMultiplier))

            Text(isIncreasing ? "Increasing" : "Decreasing")
                .font(.caption)
                .foregroundColor(.secondary)

            if isRunning {
                Button("Stop") {
                    stopTest()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
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

    private func colorForMultiplier(_ mult: Float) -> Color {
        if mult <= 1.0 {
            return .gray
        } else if mult <= 3.0 {
            return .yellow
        } else if mult <= 6.0 {
            return .orange
        } else {
            return .red
        }
    }

    private func startTest() {
        // Setup audio engine
        let engine = AudioEngine()
        do {
            try engine.setup()
            engine.setMasterVolume(1.0)
            engine.setBeatVolume(currentMultiplier)
            engine.setMetronomeVolume(1.0)
            try engine.startTempoBeats(bpm: 120) // 2 beats per second for clear feedback
            audioEngine = engine
            isRunning = true

            // Start cycling timer
            cycleTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { _ in
                stepVolume()
            }
        } catch {
            print("VolumeTestView: Failed to setup audio: \(error)")
        }
    }

    private func stopTest() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        audioEngine?.stopTempoBeats()
        audioEngine?.teardown()
        audioEngine = nil
        isRunning = false
        currentMultiplier = 0.0
        isIncreasing = true
    }

    private func stepVolume() {
        if isIncreasing {
            currentMultiplier += stepSize
            if currentMultiplier >= maxMultiplier {
                currentMultiplier = maxMultiplier
                isIncreasing = false
            }
        } else {
            currentMultiplier -= stepSize
            if currentMultiplier <= 0.0 {
                currentMultiplier = 0.0
                isIncreasing = true
            }
        }

        audioEngine?.setBeatVolume(currentMultiplier)
    }
}

#Preview {
    VolumeTestView()
}
