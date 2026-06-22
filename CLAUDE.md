# CLAUDE.md — Running Tools

## Build Number

After every set of changes, increment the build number (`CURRENT_PROJECT_VERSION`) by 1 in `pace-runner/PaceRunner/PaceRunner.xcodeproj/project.pbxproj`. Only increment the iOS app and Watch app targets (the ones currently at the highest build number — currently 21). Do NOT change the build numbers for other targets (tests, widget extensions, etc.) that are at 1. The user manages version numbers (`MARKETING_VERSION`) manually — do not change those.
