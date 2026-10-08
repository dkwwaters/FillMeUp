import Foundation

/// Owns the on-device copy of every UK forecourt and keeps it current.
///
/// The first launch downloads everything; after that only changes are
/// fetched, with a full re-download once a day so closed stations drop out.
actor StationRepository {
    struct Contents: Sendable {
        var stations: [Station]
        var updatedAt: Date?
    }

    /// Prices move a few times a day at most; don't hit the API more often.
    private static let refreshInterval: TimeInterval = 15 * 60
    private static let fullResyncInterval: TimeInterval = 24 * 60 * 60
    /// Incremental windows overlap so a price published mid-download isn't missed.
    private static let incrementalOverlap: TimeInterval = 5 * 60

    private let source: FuelDataSource
    private var stations: [String: Station] = [:]
    private var lastFullSync: Date?
    private var lastSync: Date?
    private var isSyncing = false

    init(source: FuelDataSource) {
        self.source = source
    }

    /// Loads the cached copy from disk, if there is one.
    func loadCache() -> Contents {
        if let cache = Cache.load() {
            stations = Dictionary(cache.stations.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            lastFullSync = cache.lastFullSync
            lastSync = cache.lastSync
        }
        return contents
    }

    /// Brings prices up to date. Returns nil when nothing needed doing.
    func refresh(force: Bool, progress: @escaping @Sendable (String) -> Void) async throws -> Contents? {
        guard !isSyncing else { return nil }
        let startedAt = Date()
        if !force, let lastSync, startedAt.timeIntervalSince(lastSync) < Self.refreshInterval, !stations.isEmpty {
            return nil
        }

        isSyncing = true
        defer { isSyncing = false }

        let needsFullSync = stations.isEmpty
            || lastFullSync.map { startedAt.timeIntervalSince($0) > Self.fullResyncInterval } ?? true

        if !needsFullSync, let lastSync,
           let changes = try await source.changes(since: lastSync.addingTimeInterval(-Self.incrementalOverlap), progress: progress) {
            apply(changes)
        } else {
            let snapshot = try await source.snapshot(progress: progress)
            // An empty snapshot is an upstream fault; keep what we have.
            guard !snapshot.isEmpty else { throw FuelDataError.http(status: 204, message: "No stations returned.") }
            stations = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            lastFullSync = startedAt
        }
        lastSync = startedAt

        Cache(stations: Array(stations.values), lastFullSync: lastFullSync, lastSync: lastSync).save()
        return contents
    }

    private var contents: Contents {
        Contents(stations: Array(stations.values), updatedAt: lastSync)
    }

    private func apply(_ feed: FeedChanges) {
        for record in feed.stations {
            if stations[record.nodeID] != nil {
                stations[record.nodeID]?.update(from: record)
            } else {
                stations[record.nodeID] = Station(record: record)
            }
        }
        for record in feed.prices {
            // Prices for a station we have no details for can't be placed on
            // a map, so there's nothing useful to do with them.
            stations[record.nodeID]?.merge(prices: record.prices)
        }
    }

    // MARK: - Disk cache

    private struct Cache: Codable {
        static let version = 1

        var version = Cache.version
        var stations: [Station]
        var lastFullSync: Date?
        var lastSync: Date?

        init(stations: [Station], lastFullSync: Date?, lastSync: Date?) {
            self.stations = stations
            self.lastFullSync = lastFullSync
            self.lastSync = lastSync
        }

        private static var url: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("stations-v\(version).json")
        }

        static func load() -> Cache? {
            guard let data = try? Data(contentsOf: url),
                  let cache = try? JSONDecoder().decode(Cache.self, from: data),
                  cache.version == version else { return nil }
            return cache
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
