import SwiftUI
import PaceRunnerShared

/// Modal sheet that walks the user through the manual config-sync handshake:
///   1. Reaching watch          (WCSession activation + reachability)
///   2. Sending N configs       (encode + sendMessage)
///   3. Waiting for confirmation (replyHandler + configSyncAck)
///   4. Done / Failed            (terminal)
///
/// Steps 1–3 advance on a short visual timer because the underlying
/// `forceSyncAllConfigurations` doesn't expose intermediate stages — the whole
/// thing completes in well under a second when reachable. The terminal state
/// is real, driven by the `status` binding flipping to `.synced` or `.failed`.
struct SyncProgressSheet: View {

    let configCount: Int
    let status: SyncStatus
    let onDismiss: () -> Void

    @State private var currentStep = 0
    @State private var terminalState: TerminalState?

    enum TerminalState: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: terminalState == nil
                      ? "applewatch.radiowaves.left.and.right"
                      : (isFailure ? "applewatch.slash" : "checkmark.applewatch"))
                    .font(.system(size: 48))
                    .foregroundStyle(headerColor)
                    .symbolEffect(.bounce, value: terminalState)
                Text(headerText)
                    .font(.title2.weight(.semibold))
            }
            .padding(.top, 8)

            // Steps
            VStack(alignment: .leading, spacing: 14) {
                stepRow(index: 0, label: "Reaching watch")
                stepRow(index: 1, label: "Sending \(configCount) configuration\(configCount == 1 ? "" : "s")")
                stepRow(index: 2, label: "Waiting for watch confirmation")
            }
            .padding(.horizontal, 24)

            if case .failure(let msg) = terminalState {
                Text(msg)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            // Bottom action — only present once a terminal state is reached.
            // Successful syncs auto-dismiss after a brief celebratory delay
            // so the user sees the checkmark land before the sheet closes.
            if terminalState != nil {
                Button(role: .cancel) {
                    onDismiss()
                } label: {
                    Text(isFailure ? "Close" : "Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 12)
        .onAppear { startVisualTimers() }
        .onChange(of: status) { _, newStatus in
            handleStatusChange(newStatus)
        }
        .interactiveDismissDisabled(terminalState == nil)
    }

    // MARK: - Header chrome

    private var isFailure: Bool {
        if case .failure = terminalState { return true }
        return false
    }

    private var headerColor: Color {
        switch terminalState {
        case .none: return .blue
        case .success: return .green
        case .failure: return .red
        }
    }

    private var headerText: String {
        switch terminalState {
        case .none: return "Syncing to Watch"
        case .success: return "Synced"
        case .failure: return "Sync Failed"
        }
    }

    // MARK: - Step rows

    enum StepState {
        case pending, active, done, failed
    }

    private func stepState(forIndex i: Int) -> StepState {
        if let terminal = terminalState {
            switch terminal {
            case .success: return .done
            case .failure:
                // Mark steps up to currentStep as done; the step we were on
                // when failure landed is the one that failed.
                if i < currentStep { return .done }
                if i == currentStep { return .failed }
                return .pending
            }
        }
        if i < currentStep { return .done }
        if i == currentStep { return .active }
        return .pending
    }

    private func stepRow(index: Int, label: String) -> some View {
        HStack(spacing: 12) {
            stepIcon(for: stepState(forIndex: index))
                .frame(width: 22, height: 22)
            Text(label)
                .foregroundStyle(stepState(forIndex: index) == .pending ? .secondary : .primary)
            Spacer()
        }
    }

    @ViewBuilder
    private func stepIcon(for state: StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Animation + status driving

    /// Tick the visual steps forward on a short timer. The internal sync
    /// completes much faster than these intervals when the watch is reachable
    /// — the timer just guarantees the user sees each step at least briefly.
    private func startVisualTimers() {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            await advanceIfStillRunning(to: 1)
            try? await Task.sleep(nanoseconds: 700_000_000)
            await advanceIfStillRunning(to: 2)
        }
    }

    @MainActor
    private func advanceIfStillRunning(to step: Int) {
        guard terminalState == nil, step > currentStep else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = step
        }
    }

    private func handleStatusChange(_ newStatus: SyncStatus) {
        switch newStatus {
        case .synced:
            withAnimation(.easeInOut(duration: 0.25)) {
                currentStep = 2
                terminalState = .success
            }
            // Brief pause so the checkmark is visible before the sheet
            // closes — auto-dismiss feels good for the happy path.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if terminalState == .success { onDismiss() }
            }
        case .failed(let msg):
            withAnimation(.easeInOut(duration: 0.25)) {
                terminalState = .failure(msg)
            }
        case .syncing, .activated, .notActivated, .queued:
            break
        }
    }
}

#Preview("Syncing") {
    SyncProgressSheet(configCount: 4, status: .syncing, onDismiss: {})
        .presentationDetents([.medium])
}

#Preview("Succeeded") {
    SyncProgressSheet(configCount: 4, status: .synced, onDismiss: {})
        .presentationDetents([.medium])
}

#Preview("Failed") {
    SyncProgressSheet(configCount: 4, status: .failed("Watch not reachable — queued for later"), onDismiss: {})
        .presentationDetents([.medium])
}
