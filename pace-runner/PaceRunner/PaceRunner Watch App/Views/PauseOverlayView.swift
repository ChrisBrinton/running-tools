import SwiftUI

struct PauseOverlayView: View {
    let resumeAction: () -> Void
    let endAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Paused")
                .font(.title2)

            HStack {
                Button("Resume", action: resumeAction)
                    .buttonStyle(.borderedProminent)

                Button("End", action: endAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .foregroundStyle(.white)
    }
}

#Preview {
    PauseOverlayView(resumeAction: {}, endAction: {})
}
