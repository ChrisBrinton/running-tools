import Foundation

/// Pure, deterministic merge for the run-configuration set that syncs between
/// iPhone and Apple Watch.
///
/// The old model was "replace-all, last-writer-wins": receiving a full set
/// overwrote local storage. That silently destroyed a config the other device
/// had just created but the sender didn't yet know about. This merges by `id`
/// instead, so a configuration created on either device survives, and uses
/// **tombstones** so an intentional delete still propagates (a plain union can
/// never delete anything — the deleted config just comes back from the peer).
///
/// Rules:
/// - Union by `id`. A config present on either side is kept.
/// - On an `id` collision the **incoming** copy wins (it's the more recent edit
///   pushed by the peer). There is no per-config modified-time, so genuinely
///   concurrent edits to the same `id` resolve by arrival order — acceptable
///   because configs are rarely edited on both devices at once.
/// - **Delete wins**: a tombstoned `id` is removed even if a live copy is still
///   floating around. New configs always get fresh UUIDs, so a tombstone can't
///   wrongly suppress a later re-creation.
/// - Order: existing local order is preserved; configs seen only from the peer
///   are appended.
/// - Tombstones older than ``tombstoneTTL`` are pruned — long enough for every
///   device to have observed the delete, bounded so the set can't grow forever.
public enum ConfigurationMerge {

    public struct Result: Equatable {
        public let configurations: [RunConfiguration]
        /// id → time the delete was recorded.
        public let tombstones: [UUID: Date]

        public init(configurations: [RunConfiguration], tombstones: [UUID: Date]) {
            self.configurations = configurations
            self.tombstones = tombstones
        }
    }

    /// How long a delete is remembered. 30 days.
    public static let tombstoneTTL: TimeInterval = 30 * 24 * 60 * 60

    public static func merge(
        local: [RunConfiguration],
        localTombstones: [UUID: Date],
        incoming: [RunConfiguration],
        incomingTombstones: [UUID: Date],
        now: Date
    ) -> Result {
        // 1. Union tombstones (newest deletedAt per id), then prune expired ones.
        var tombstones = localTombstones
        for (id, date) in incomingTombstones {
            if let existing = tombstones[id] {
                tombstones[id] = Swift.max(existing, date)
            } else {
                tombstones[id] = date
            }
        }
        let cutoff = now.addingTimeInterval(-tombstoneTTL)
        tombstones = tombstones.filter { $0.value >= cutoff }

        // 2. Upsert local then incoming (incoming wins on collision), preserving
        //    first-seen order.
        var byId: [UUID: RunConfiguration] = [:]
        var order: [UUID] = []
        for config in local {
            if byId[config.id] == nil { order.append(config.id) }
            byId[config.id] = config
        }
        for config in incoming {
            if byId[config.id] == nil { order.append(config.id) }
            byId[config.id] = config
        }

        // 3. Delete wins: drop any id with a (non-expired) tombstone.
        let configurations = order.compactMap { id -> RunConfiguration? in
            guard tombstones[id] == nil else { return nil }
            return byId[id]
        }

        return Result(configurations: configurations, tombstones: tombstones)
    }
}
