//
//  PaceRunnerApp.swift
//  PaceRunner Watch App
//
//  Created by Christopher Brinton on 11/17/25.
//

import SwiftUI
import PaceRunnerShared

@main
struct PaceRunner_Watch_AppApp: App {
    private let workoutManager: WorkoutManagerProtocol
    private let syncManager: SyncManagerProtocol
    @StateObject private var configurationStore: ConfigurationStore
    @StateObject private var workoutStore: WatchWorkoutStore

    init() {
        let syncManager = SyncManager()
        syncManager.activate()
        self.syncManager = syncManager
        self.workoutManager = WorkoutManager(
            gpsManager: GPSManager(),
            paceCalculator: PaceCalculator(),
            audioEngine: AudioEngine()
        )
        _configurationStore = StateObject(wrappedValue: ConfigurationStore(syncManager: syncManager))
        _workoutStore = StateObject(wrappedValue: WatchWorkoutStore(syncManager: syncManager))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let configuration = configurationStore.selectedConfiguration {
                    WorkoutContainerView(
                        configuration: configuration,
                        workoutManager: workoutManager,
                        syncManager: syncManager,
                        workoutStore: workoutStore,
                        onExit: { configurationStore.clearSelection() }
                    )
                } else {
                    ConfigurationSelectionView(store: configurationStore)
                }
            }
        }
    }
}
