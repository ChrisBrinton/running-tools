//
//  PaceRunnerApp.swift
//  PaceRunner
//
//  Created by Christopher Brinton on 11/17/25.
//

import SwiftUI
import UserNotifications
import PaceRunnerShared

@main
struct PaceRunnerApp: App {

    private let syncManager: SyncManagerProtocol
    private let workoutManager: WorkoutManagerProtocol
    @StateObject private var configurationStore: ConfigurationStore
    @StateObject private var historyStore: WorkoutHistoryStore
    @StateObject private var entitlementManager = EntitlementManager()

    init() {
        // Suppress iOS NavigationBar constraint warnings (iOS 17 system bug)
        UserDefaults.standard.setValue(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")

        // Cap retained synced debug logs and purge legacy multi-MB UserDefaults
        // keys that older builds wrote (see DebugLogStore.init).
        DebugLogStore.shared.pruneOldLogs(keepingMostRecent: 20)

        let syncManager = SyncManager()
        syncManager.activate()
        // Symmetric cleanup on iPhone — same leak applied if/when the phone
        // ever called transferFile (and surfaces queue size for diagnostics).
        syncManager.cleanupStaleSyncState()
        self.syncManager = syncManager

        // Eager-init the publisher so its `didBecomeActive` observer is wired
        // before the first foreground transition. publishAll on launch is
        // gated by isConfigured, so this is safe even for fresh installs.
        // Also: bake in the home-server URL from Info.plist so users don't
        // need to type it — they just register and connect.
        let publisher = HealthKitPublisher.shared
        let buildURL = PublisherConfig.serverBaseURL.absoluteString
        if publisher.serverURL != buildURL {
            publisher.serverURL = buildURL
        }

        // Workout manager for iPhone-side workouts (no HKWorkoutSession on iOS,
        // background location/audio modes keep the app alive)
        self.workoutManager = WorkoutManager(
            gpsManager: GPSManager(),
            paceCalculator: PaceCalculator(),
            audioEngine: AudioEngine()
        )

        // Sync settings to watch on startup
        syncManager.syncSettings(AppSettings.load())

        // Request notification permission for workout sync alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[PaceRunnerApp] Notification auth error: \(error)")
            } else {
                print("[PaceRunnerApp] Notification auth granted: \(granted)")
            }
        }

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
                iOSRunTabView(
                    configurationStore: configurationStore,
                    workoutManager: workoutManager,
                    syncManager: syncManager
                )
                .tabItem {
                    Label("Run", systemImage: "figure.run")
                }

                ConfigurationListView(store: configurationStore)
                    .tabItem {
                        Label("Configurations", systemImage: "list.clipboard")
                    }

                WorkoutHistoryView(store: historyStore)
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }

                MCPServerView()
                    .tabItem {
                        Label("MCP", systemImage: "antenna.radiowaves.left.and.right")
                    }

                SettingsView(syncManager: syncManager, configurationStore: configurationStore, historyStore: historyStore)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .environmentObject(entitlementManager)
            .onReceive(entitlementManager.$isPro) { isPro in
                syncManager.syncEntitlements(isPro: isPro)
            }
            .onReceive(NotificationCenter.default.publisher(for: .allDataRequested)) { _ in
                // Watch requested all data — push everything
                syncManager.syncAllConfigurations(configurationStore.configurations)
                syncManager.syncSettings(AppSettings.load())
                syncManager.syncEntitlements(isPro: entitlementManager.isPro)
            }
        }
    }
}
