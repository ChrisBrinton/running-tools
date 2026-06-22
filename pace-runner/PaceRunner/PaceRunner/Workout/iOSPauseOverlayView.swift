import SwiftUI

struct iOSPauseOverlayView: View {
    let resumeAction: () -> Void
    let endAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.white)

            Text("Paused")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)

            VStack(spacing: 12) {
                Button(action: resumeAction) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Resume")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)

                Button(role: .destructive, action: endAction) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("End Workout")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}
