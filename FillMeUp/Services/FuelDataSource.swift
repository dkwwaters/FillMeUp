import Foundation

/// Station and price records that changed since a point in time.
struct FeedChanges: Sendable {
    var stations: [StationRecord]
    var prices: [PriceRecord]
}

/// Somewhere to get fuel prices from.
protocol FuelDataSource: Sendable {
    /// Every station, with its current prices.
    func snapshot(progress: @escaping @Sendable (String) -> Void) async throws -> [Station]
    /// Only what has changed since `date`, or nil if this source can't do
    /// incremental updates (the caller then takes a full snapshot).
    func changes(since date: Date, progress: @escaping @Sendable (String) -> Void) async throws -> FeedChanges?
}

enum FuelDataSources {
    /// Picks a source from the build configuration (see Config/Base.xcconfig).
    ///
    /// Release builds only ever use the Fill Me Up proxy: Fuel Finder's terms
    /// forbid putting OAuth client secrets in a mobile app. Debug builds may
    /// call the API directly so the app can be tried before the proxy exists.
    static func configured(bundle: Bundle = .main) -> FuelDataSource? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unset build settings come through empty; placeholders from the
            // example file count as unset too.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), !trimmed.hasPrefix("your-") else { return nil }
            return trimmed
        }

        if let host = value("FillMeUpAPIHost"), let url = URL(string: "https://\(host)/v1/stations") {
            return ProxyFuelSource(endpoint: url, appKey: value("FillMeUpAPIKey"))
        }
        #if DEBUG
        if let id = value("FuelFinderClientID"), let secret = value("FuelFinderClientSecret") {
            let client = FuelFinderClient(credentials: .init(clientID: id, clientSecret: secret),
                                          host: value("FuelFinderAPIHost") ?? FuelFinderClient.liveHost)
            return DirectFuelSource(client: client)
        }
        #endif
        return nil
    }
}

/// Fetches straight from the Fuel Finder API. Debug builds only.
struct DirectFuelSource: FuelDataSource {
    let client: FuelFinderClient

    func snapshot(progress: @escaping @Sendable (String) -> Void) async throws -> [Station] {
        let stations = try await client.stations(since: nil) { page in progress("Downloading stations (page \(page))…") }
        let prices = try await client.prices(since: nil) { page in progress("Downloading prices (page \(page))…") }
        var byID: [String: Station] = [:]
        for record in stations { byID[record.nodeID] = Station(record: record) }
        for record in prices { byID[record.nodeID]?.merge(prices: record.prices) }
        return Array(byID.values)
    }

    func changes(since date: Date, progress: @escaping @Sendable (String) -> Void) async throws -> FeedChanges? {
        progress("Checking for new prices…")
        let stations = try await client.stations(since: date) { _ in }
        let prices = try await client.prices(since: date) { _ in }
        return FeedChanges(stations: stations, prices: prices)
    }
}

/// Fetches every station in one request from the Fill Me Up proxy (see
/// /FillMeUp/proxy), which holds the API credentials server-side and serves
/// the app's own trimmed-down format rather than raw API data.
struct ProxyFuelSource: FuelDataSource {
    let endpoint: URL
    let appKey: String?

    func snapshot(progress: @escaping @Sendable (String) -> Void) async throws -> [Station] {
        progress("Updating prices…")
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let appKey { request.setValue(appKey, forHTTPHeaderField: "X-App-Key") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw FuelDataError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw FuelDataError.http(status: status, message: APIMessage.extract(from: data))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = FeedDate.parse(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
            }
            return date
        }
        return try decoder.decode(ProxyPayload.self, from: data).stations.elements
    }

    func changes(since date: Date, progress: @escaping @Sendable (String) -> Void) async throws -> FeedChanges? {
        nil   // the whole snapshot is a single compressed request
    }

    private struct ProxyPayload: Decodable {
        var stations: LossyArray<Station>
    }
}
