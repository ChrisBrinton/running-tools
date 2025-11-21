import Foundation
import Combine
import PaceRunnerShared

final class WorkoutManagerPreview: WorkoutManagerProtocol {
    private let subject: CurrentValueSubject<WorkoutState, Never>
    private static let previewConfiguration = RunConfiguration(
        name: "Preview Run",
        distance: Distance(miles: 5),
        targetPace: Pace(minutes: 8, seconds: 0),
        baseCadence: 180,
        paceTolerance: 5
    )

    init() {
        subject = CurrentValueSubject(WorkoutState(configuration: Self.previewConfiguration))
    }

    var statePublisher: AnyPublisher<WorkoutState, Never> {
        subject.eraseToAnyPublisher()
    }

    var currentState: WorkoutState? {
        subject.value
    }

    func startWorkout(with configuration: RunConfiguration) throws {}
    func pauseWorkout() throws {}
    func resumeWorkout() throws {}
    func endWorkout() throws -> WorkoutSummary {
        WorkoutSummary(
            configurationName: "Preview Run",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            totalDistance: Distance(miles: 5),
            averagePace: Pace(minutes: 8, seconds: 0),
            mileSplits: []
        )
    }
    func cancelWorkout() {}
}
