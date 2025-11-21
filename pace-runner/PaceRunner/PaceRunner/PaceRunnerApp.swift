//
//  PaceRunnerApp.swift
//  PaceRunner
//
//  Created by Christopher Brinton on 11/17/25.
//

import SwiftUI
import PaceRunnerShared

@main
struct PaceRunnerApp: App {

    private let syncManager: SyncManagerProtocol
    @StateObject private var configurationStore: ConfigurationStore
    @StateObject private var historyStore: WorkoutHistoryStore

    init() {
        // Suppress iOS NavigationBar constraint warnings (iOS 17 system bug)
        UserDefaults.standard.setValue(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")

        let syncManager = SyncManager()
        syncManager.activate()
        self.syncManager = syncManager

        _configurationStore = StateObject(
            wrappedValue: ConfigurationStore(syncManager: syncManager)
        )
        _historyStore = StateObject(
            wrappedValue: WorkoutHistoryStore(syncManager: syncManager)
        )
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ConfigurationListView(store: configurationStore)
                    .tabItem {
                        Label("Configurations", systemImage: "list.clipboard")
                    }

                WorkoutHistoryView(store: historyStore)
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
            }
        }
    }
}
