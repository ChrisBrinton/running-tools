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
    @StateObject private var entitlementManager = EntitlementManager()

    init() {
        // Cap retained debug logs so Caches/debugLogs/ can't grow unbounded.
        // DebugLogStore.init() also purges legacy multi-MB UserDefaults keys
        // (`lastDebugLog`, `lastWatchDebugLog`) from older builds — those were
        // bloating standard.plist enough to break app relaunch.
        DebugLogStore.shared.pruneOldLogs(keepingMostRecent: 5)

        let syncManager = SyncManager()
        syncManager.activate()
        // After activation, sweep orphaned temp files and cancel any stale
        // debug-log transfers in the WCSession queue. These were leaking on
        // older builds and are the most likely cause of overnight lockups.
        syncManager.cleanupStaleSyncState()
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
                        onExit: { configurationStore.clearSelection() },
                        onNewRun: { newConfig in
                            // Check for existing config with same name, otherwise create
                            let configToSelect: RunConfiguration
                            if let existing = configurationStore.configuration(named: newConfig.name) {
                                configToSelect = existing
                            } else {
                                configurationStore.createConfiguration(newConfig)
                                configToSelect = newConfig
                            }
                            // Clear selection first to force WorkoutContainerView to remount,
                            // then re-select after a brief delay so SwiftUI completes the view cycle
                            configurationStore.clearSelection()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                configurationStore.select(configToSelect)
                            }
                        }
                    )
                } else {
                    ConfigurationSelectionView(store: configurationStore, workoutStore: workoutStore, syncManager: syncManager)
                }
            }
            .environmentObject(entitlementManager)
            .onReceive(NotificationCenter.default.publisher(for: .workoutDidEnd)) { notification in
                // Sync the debug log to the phone after every workout end.
                // Pass the workout ID so the phone can store it per-workout
                // for the in-app map view.
                let summary = notification.object as? WorkoutSummary
                if let logText = WorkoutManager.loadLastDebugLog() {
                    syncManager.syncDebugLog(logText, workoutID: summary?.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsSynced)) { notification in
                let syncedSettings: AppSettings
                if let s = notification.object as? AppSettings {
                    syncedSettings = s
                } else {
                    syncedSettings = AppSettings.load()
                }
                // Apply debug Pro override from synced settings
                if syncedSettings.debugProOverride != entitlementManager.isPro {
                    entitlementManager.debugSetPro(syncedSettings.debugProOverride)
                }
            }
        }
    }
}
