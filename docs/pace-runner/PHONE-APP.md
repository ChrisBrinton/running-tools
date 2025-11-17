# iPhone App Specification

## Overview

The iPhone app serves as the configuration and management interface for PaceRunner. Users create and edit run configurations, sync them to the Apple Watch, and review workout history. The phone is not required during workouts.

## User Interface

### Screen Navigation

```
Tab Bar Root:
├─ Workouts Tab
│  ├─ Workout List
│  │  └─ Workout Detail
│  └─ Create/Edit Configuration
│     └─ Mile Pace Editor
├─ History Tab
│  └─ Workout Summary Detail
└─ Settings Tab
```

## Screens

### 1. Workouts Tab - Configuration List

**Purpose**: Display all saved run configurations

**Layout**:
```
┌────────────────────────────┐
│  ≡  Workouts          [+]  │← Navigation bar
├────────────────────────────┤
│                            │
│ ┌────────────────────────┐│
│ │ Marathon - Even        ││
│ │ 26.2 mi • 8:00/mi     ││
│ │ Modified 2 days ago    ││
│ └────────────────────────┘│
│                            │
│ ┌────────────────────────┐│
│ │ 10 Mile Progressive    ││
│ │ 10.0 mi • 8:00→7:15   ││
│ │ Modified 1 week ago    ││
│ └────────────────────────┘│
│                            │
│ ┌────────────────────────┐│
│ │ Easy Long Run          ││
│ │ 15.0 mi • 9:00/mi     ││
│ │ Modified 3 weeks ago   ││
│ └────────────────────────┘│
│                            │
└────────────────────────────┘
```

**Components**:
- Navigation bar with title and add button
- List of RunConfiguration cards showing:
  - Name
  - Distance and pace summary
  - Last modified date
  - Sync status indicator
- Empty state when no configurations
- Pull to refresh (syncs from watch)

**Actions**:
- Tap card → Navigate to Configuration Detail
- Tap [+] → Navigate to Create Configuration
- Swipe left → Delete with confirmation
- Long press → Context menu (Edit, Duplicate, Delete, Sync to Watch)

**Sync Status Indicators**:
- ✓ Synced to watch
- ⟳ Sync pending
- ⚠ Sync failed

### 2. Configuration Detail Screen

**Purpose**: View and edit a run configuration

**Layout**:
```
┌────────────────────────────┐
│ < Back    Marathon - Even  │
│           [Edit]           │
├────────────────────────────┤
│                            │
│ OVERVIEW                   │
│ Distance: 26.2 miles       │
│ Average Pace: 8:00/mi      │
│ Total Time: ~3:29:52       │
│                            │
│ PACE TARGETS               │
│ ┌────────────────────────┐│
│ │ Mile 1-26  │  8:00/mi  ││
│ │ Mile 27    │  Finish   ││
│ └────────────────────────┘│
│                            │
│ SETTINGS                   │
│ Base Cadence: 180 SPM      │
│ Pace Tolerance: ±5 sec     │
│                            │
│ ┌────────────────────────┐│
│ │  Sync to Apple Watch   ││
│ └────────────────────────┘│
│                            │
│ Last synced: 2 hours ago   │
│                            │
└────────────────────────────┘
```

**Components**:
- Overview section with calculated stats
- Pace targets summary (expandable list)
- Settings controls
- Sync button with status
- Edit button in navigation bar

**Actions**:
- Tap Edit → Enable editing mode
- Tap Pace Targets → Expand to show all miles
- Tap Settings values → Show picker/slider
- Tap Sync button → Sync to watch immediately

### 3. Create/Edit Configuration Screen

**Purpose**: Create a new run or edit existing configuration

**Layout**:
```
┌────────────────────────────┐
│ < Cancel  New Workout Save │
├────────────────────────────┤
│                            │
│ NAME                       │
│ ┌────────────────────────┐│
│ │ Marathon - Even        ││
│ └────────────────────────┘│
│                            │
│ DISTANCE                   │
│ ┌─────┬──────────────────┐│
│ │26.2 │ miles ▾          ││
│ └─────┴──────────────────┘│
│                            │
│ PACE STRATEGY              │
│ ( ) Even Pace              │
│ (•) Progressive            │
│ ( ) Custom                 │
│                            │
│ BASE PACE                  │
│ ┌──────────────────────┐  │
│ │     8 : 00           │  │
│ │   ─────┴─────        │  │
│ │   min    sec         │  │
│ └──────────────────────┘  │
│                            │
│ [Configure Mile Paces →]  │
│                            │
└────────────────────────────┘
```

**Components**:
- Text field for name
- Distance input (numeric + unit picker)
- Pace strategy selector:
  - Even Pace: All miles same pace
  - Progressive: Gradual pace increase
  - Custom: Manually set each mile
- Base pace picker (digital crown style)
- Configure button to access mile editor

**Validation**:
- Name: Required, 1-50 characters
- Distance: 0.1-50.0 miles
- Pace: 4:00-20:00 per mile

**Actions**:
- Tap Save → Validate and save configuration
- Tap Cancel → Discard changes with confirmation
- Tap Configure → Navigate to Mile Pace Editor

### 4. Mile Pace Editor Screen

**Purpose**: Set individual mile pace targets

**Layout**:
```
┌────────────────────────────┐
│ < Back    Mile Paces  Done │
├────────────────────────────┤
│                            │
│ ┌────────────────────────┐│
│ │ Apply to all:          ││
│ │ [Even] [Progressive]   ││
│ └────────────────────────┘│
│                            │
│ Mile 1  │ 8:00 /mi    [>]││
│ Mile 2  │ 8:00 /mi    [>]││
│ Mile 3  │ 7:55 /mi    [>]││
│ Mile 4  │ 7:55 /mi    [>]││
│ Mile 5  │ 7:50 /mi    [>]││
│ Mile 6  │ 7:50 /mi    [>]││
│ ...                        │
│ Mile 26 │ 7:15 /mi    [>]││
│                            │
│ ┌────────────────────────┐│
│ │ Chart View             ││← Toggle button
│ └────────────────────────┘│
│                            │
└────────────────────────────┘
```

**Components**:
- Quick apply buttons (Even, Progressive, Custom)
- List of all miles with pace inputs
- Chart view toggle
- Individual mile tap → Pace picker sheet

**Quick Apply Functions**:
- **Even**: Set all miles to same pace
- **Progressive**: Linear progression from start to end pace
- **Custom**: User edits each mile individually

**Alternative View - Chart**:
```
┌────────────────────────────┐
│ < Back    Mile Paces  Done │
├────────────────────────────┤
│                            │
│ Pace Chart                 │
│  9:00├──────────────────   │
│  8:30│     ╱╱╱╱╱╱╱╱       │
│  8:00│────╱              │
│  7:30│                    │
│  7:00└──────────────────   │
│       1  5  10  15  20 26  │
│       Miles                │
│                            │
│ [List View]                │
│                            │
│ Tap chart to edit mile     │
│                            │
└────────────────────────────┘
```

**Actions**:
- Tap mile row → Show pace picker
- Tap Quick Apply → Apply pattern with confirmation
- Toggle List/Chart view
- Tap chart point → Edit that mile's pace

### 5. Pace Picker Sheet

**Purpose**: Select pace for a specific mile

**Layout**:
```
┌────────────────────────────┐
│        Mile 3 Pace         │
├────────────────────────────┤
│                            │
│      ┌───────────┐         │
│      │     7     │         │
│      └───────────┘         │
│           :                │
│      ┌───────────┐         │
│      │    45     │         │
│      └───────────┘         │
│      per mile              │
│                            │
│ ┌────────────────────────┐│
│ │        Set Pace        ││
│ └────────────────────────┘│
│                            │
│ ┌────────────────────────┐│
│ │        Cancel          ││
│ └────────────────────────┘│
│                            │
└────────────────────────────┘
```

**Components**:
- Dual picker wheels (minutes, seconds)
- Set Pace button
- Cancel button

**Validation**:
- Range: 4:00 to 20:00 per mile
- Seconds: 0-59

### 6. History Tab - Workout List

**Purpose**: View past workout summaries

**Layout**:
```
┌────────────────────────────┐
│  ≡  Workout History        │
├────────────────────────────┤
│ November 2024              │
│                            │
│ ┌────────────────────────┐│
│ │ Mon Nov 4 • 26.2 mi    ││
│ │ Marathon - Even        ││
│ │ 3:28:15 • 7:58/mi avg  ││
│ │ ━━━━━━━━━━━━━━━━━━━━━ ││
│ │ ✓ On pace              ││
│ └────────────────────────┘│
│                            │
│ ┌────────────────────────┐│
│ │ Sat Nov 2 • 10.0 mi    ││
│ │ Easy Long Run          ││
│ │ 1:30:22 • 9:02/mi avg  ││
│ │ ━━━━━━━━━━━━━━━━━━━━━ ││
│ │ ⚠ 2s slow              ││
│ └────────────────────────┘│
│                            │
│ October 2024               │
│ ...                        │
│                            │
└────────────────────────────┘
```

**Components**:
- Grouped by month
- Workout cards showing:
  - Date and distance
  - Configuration name
  - Duration and average pace
  - Performance indicator (on pace, fast, slow)
- Empty state when no history

**Actions**:
- Tap card → Navigate to Workout Summary Detail
- Pull to refresh → Sync from watch
- Swipe left → Delete with confirmation

### 7. Workout Summary Detail

**Purpose**: Detailed view of completed workout

**Layout**:
```
┌────────────────────────────┐
│ < Back    Nov 4, 2024      │
├────────────────────────────┤
│                            │
│ Marathon - Even            │
│                            │
│ SUMMARY                    │
│ Distance: 26.2 mi          │
│ Duration: 3:28:15          │
│ Avg Pace: 7:58/mi          │
│                            │
│ PERFORMANCE                │
│ On Target: 22 miles        │
│ Too Fast: 2 miles          │
│ Too Slow: 2 miles          │
│                            │
│ MILE SPLITS                │
│ Mile 1  7:52  -8s  ━━━●━━ │
│ Mile 2  8:05  +5s  ━━━━●━ │
│ Mile 3  7:58  ±0s  ━━━●━━ │
│ Mile 4  7:55  -5s  ━━●━━━ │
│ ...                        │
│ Mile 26 7:45 -15s  ━●━━━━ │
│                            │
│ [Export to Health]         │
│ [Share Workout]            │
│                            │
└────────────────────────────┘
```

**Components**:
- Workout metadata
- Summary statistics
- Performance breakdown
- Mile-by-mile splits with:
  - Actual pace
  - Deviation from target
  - Visual indicator (bar chart)
- Export/Share buttons

**Actions**:
- Tap Export → Save to Apple Health (if not already saved)
- Tap Share → Share sheet with summary text/image

### 8. Settings Tab

**Purpose**: App-wide preferences

**Layout**:
```
┌────────────────────────────┐
│  ≡  Settings               │
├────────────────────────────┤
│                            │
│ PREFERENCES                │
│ Units            [Miles ▾] │
│ Audio Alerts     [ON]      │
│ Tempo Beats      [ON]      │
│ Haptic Feedback  [ON]      │
│                            │
│ DEFAULTS                   │
│ Base Cadence     180 SPM   │
│ Pace Tolerance   ±5 sec    │
│                            │
│ APPLE WATCH                │
│ Connected        [✓]       │
│ Last Sync        2 hrs ago │
│ [Sync Now]                 │
│                            │
│ ABOUT                      │
│ Version          1.0.0     │
│ [Privacy Policy]           │
│ [Support]                  │
│                            │
└────────────────────────────┘
```

**Components**:
- Unit preferences (Miles/Kilometers)
- Audio/haptic toggles
- Default values for new configurations
- Watch connection status
- About section

**Actions**:
- Tap preferences → Toggle or show picker
- Tap Sync Now → Force sync with watch
- Tap links → Open in Safari

## View Models

### ConfigurationListViewModel

```swift
class ConfigurationListViewModel: ObservableObject {
    @Published var configurations: [RunConfiguration] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let dataStore: DataStore
    private let syncManager: SyncManager
    
    func loadConfigurations()
    func createConfiguration(_ config: RunConfiguration)
    func updateConfiguration(_ config: RunConfiguration)
    func deleteConfiguration(_ id: UUID)
    func syncToWatch(_ id: UUID)
    func syncAllToWatch()
}
```

### ConfigurationEditorViewModel

```swift
class ConfigurationEditorViewModel: ObservableObject {
    @Published var configuration: RunConfiguration
    @Published var isValid = false
    @Published var errorMessage: String?
    
    enum PaceStrategy {
        case even
        case progressive(start: Pace, end: Pace)
        case custom
    }
    
    func updateName(_ name: String)
    func updateDistance(_ distance: Distance)
    func applyPaceStrategy(_ strategy: PaceStrategy)
    func updateMilePace(mile: Int, pace: Pace)
    func validate() -> Bool
    func save() throws
}
```

### WorkoutHistoryViewModel

```swift
class WorkoutHistoryViewModel: ObservableObject {
    @Published var workouts: [WorkoutSummary] = []
    @Published var isLoading = false
    
    private let dataStore: DataStore
    private let syncManager: SyncManager
    
    func loadWorkouts()
    func deleteWorkout(_ id: UUID)
    func syncFromWatch()
    
    // Group workouts by month
    func groupedWorkouts() -> [String: [WorkoutSummary]]
}
```

## Services

### SyncManager

Handles WatchConnectivity for data synchronization.

```swift
class SyncManager: NSObject, WCSessionDelegate, ObservableObject {
    @Published var isWatchConnected = false
    @Published var lastSyncDate: Date?
    
    private var session: WCSession?
    private let dataStore: DataStore
    
    func setupSession()
    func syncConfiguration(_ config: RunConfiguration)
    func syncAllConfigurations()
    func requestWorkoutHistory()
    
    // WCSessionDelegate methods
    func session(_ session: WCSession, 
                didReceiveMessage message: [String: Any])
    func session(_ session: WCSession, 
                didReceive file: WCSessionFile)
}
```

### DataManager

Manages local data persistence.

```swift
class DataManager {
    private let dataStore: DataStore
    
    func saveConfiguration(_ config: RunConfiguration) throws
    func loadConfigurations() -> [RunConfiguration]
    func deleteConfiguration(_ id: UUID) throws
    
    func saveWorkoutSummary(_ summary: WorkoutSummary) throws
    func loadWorkoutHistory() -> [WorkoutSummary]
    func deleteWorkoutSummary(_ id: UUID) throws
}
```

## Data Flow

### Creating a Configuration

```
User Input → ConfigurationEditorViewModel
            ↓ validate()
         Valid? → Save to DataStore
                  ↓
               SyncManager.syncConfiguration()
                  ↓
            WCSession.transferUserInfo()
                  ↓
              Watch receives
                  ↓
            Watch saves locally
```

### Receiving Workout Summary

```
Watch completes workout
    ↓
Watch saves summary locally
    ↓
WCSession.transferFile()
    ↓
Phone receives file
    ↓
SyncManager.didReceive(file)
    ↓
Parse WorkoutSummary
    ↓
Save to DataStore
    ↓
Update WorkoutHistoryViewModel
    ↓
UI refreshes automatically
```

## Error Handling

### Validation Errors
- Show inline error messages
- Disable Save button until valid
- Highlight invalid fields in red

### Sync Errors
- Display toast notification
- Show retry button
- Queue failed syncs for later

### Data Errors
- Graceful degradation (show cached data)
- Error banner with retry option
- Log errors for debugging

## Testing Scenarios

### Configuration Management
1. Create new even-pace configuration
2. Create progressive configuration
3. Create custom configuration with 26 different paces
4. Edit existing configuration
5. Delete configuration
6. Duplicate configuration

### Sync Testing
1. Create config on phone, verify appears on watch
2. Complete workout on watch, verify appears in phone history
3. Test sync when watch disconnected
4. Test sync retry mechanism

### Data Validation
1. Try to save configuration with invalid name
2. Try to save with invalid distance
3. Try to save with invalid pace
4. Verify all validation messages display correctly

## Accessibility

- VoiceOver labels for all controls
- Dynamic Type support (text scales)
- High contrast mode support
- Reduced motion option
- Minimum touch target size: 44x44 pt

## Localization

Initially English only. Structure supports future localization:
- All strings in Localizable.strings
- Date/time formatters respect locale
- Distance units based on region

## Privacy & Permissions

Required permissions:
- HealthKit: Write workouts (optional)
- No location permission needed on phone

Privacy:
- All data stored locally
- No analytics or telemetry
- No external network requests
- User controls all data via Settings
