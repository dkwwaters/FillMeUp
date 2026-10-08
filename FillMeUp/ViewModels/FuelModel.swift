import Foundation
import CoreLocation
import Observation

struct StationResult: Identifiable, Hashable {
    let station: Station
    let price: FuelPrice
    let miles: Double

    var id: String { station.id }

    var distanceText: String {
        miles < 0.1 ? "Nearby" : String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
    }
}

enum NavigationApp: String, CaseIterable, Identifiable {
    case appleMaps, googleMaps, waze

    var id: String { rawValue }

    var name: String {
        switch self {
        case .appleMaps:  return "Apple Maps"
        case .googleMaps: return "Google Maps"
        case .waze:       return "Waze"
        }
    }

    /// Universal links: open the app when installed, the website otherwise.
    func directionsURL(to c: CLLocationCoordinate2D) -> URL {
        let ll = "\(c.latitude),\(c.longitude)"
        switch self {
        case .appleMaps:  return URL(string: "https://maps.apple.com/?daddr=\(ll)&dirflg=d")!
        case .googleMaps: return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(ll)&travelmode=driving")!
        case .waze:       return URL(string: "https://waze.com/ul?ll=\(ll)&navigate=yes")!
        }
    }

    /// App URL schemes, which CarPlay needs to hand off to another CarPlay app.
    func carPlayURL(to c: CLLocationCoordinate2D) -> URL {
        let ll = "\(c.latitude),\(c.longitude)"
        switch self {
        case .appleMaps:  return URL(string: "maps://?daddr=\(ll)&dirflg=d")!
        case .googleMaps: return URL(string: "comgooglemaps://?daddr=\(ll)&directionsmode=driving")!
        case .waze:       return URL(string: "waze://?ll=\(ll)&navigate=yes")!
        }
    }
}

/// App-wide state shared by the phone UI and CarPlay.
@MainActor
@Observable
final class FuelModel {
    static let shared = FuelModel()

    /// Posted whenever results or status change, for the (non-SwiftUI) CarPlay UI.
    static let didChange = Notification.Name("FuelModel.didChange")

    static let radiusOptions: [Double] = [1, 3, 5, 10, 15, 25]
    /// Older prices are probably wrong, and a wrong "cheapest" is worse than none.
    private static let maxPriceAge: TimeInterval = 14 * 24 * 60 * 60

    enum Status: Equatable {
        case idle
        case loading(String)
        case failed(String)
    }

    let location = LocationService()

    var fuel: FuelType {
        didSet {
            UserDefaults.standard.set(fuel.code, forKey: Keys.fuel)
            recomputeResults()
        }
    }

    var radiusMiles: Double {
        didSet {
            UserDefaults.standard.set(radiusMiles, forKey: Keys.radius)
            recomputeResults()
        }
    }

    /// The last app the user navigated with; CarPlay uses it directly.
    var navigationApp: NavigationApp {
        didSet { UserDefaults.standard.set(navigationApp.rawValue, forKey: Keys.navigation) }
    }

    private(set) var results: [StationResult] = []
    private(set) var status: Status = .idle {
        didSet { if status != oldValue { notifyChange() } }
    }
    private(set) var updatedAt: Date?
    private(set) var hasStations = false

    var isConfigured: Bool { repository != nil }

    @ObservationIgnored private let repository: StationRepository?
    @ObservationIgnored private var stations: [Station] = []
    @ObservationIgnored private var resultsOrigin: CLLocation?
    @ObservationIgnored private var started = false

    private enum Keys {
        static let fuel = "fuelType"
        static let radius = "radiusMiles"
        static let navigation = "navigationApp"
    }

    private init() {
        let defaults = UserDefaults.standard
        fuel = defaults.string(forKey: Keys.fuel).map { FuelType($0) } ?? .e10
        let savedRadius = defaults.double(forKey: Keys.radius)
        radiusMiles = Self.radiusOptions.contains(savedRadius) ? savedRadius : 5
        navigationApp = defaults.string(forKey: Keys.navigation).flatMap { NavigationApp(rawValue: $0) } ?? .appleMaps
        repository = FuelDataSources.configured().map { StationRepository(source: $0) }

        location.onUpdate = { [weak self] newLocation in
            self?.locationDidUpdate(newLocation)
        }
    }

    /// Called by whichever screen appears first (phone or CarPlay).
    func start() async {
        location.start()
        guard !started, let repository else { return }
        started = true

        let cached = await repository.loadCache()
        apply(cached)
        await refresh(force: false)
    }

    func refresh(force: Bool) async {
        guard let repository else {
            status = .failed(FuelDataError.notConfigured.localizedDescription)
            return
        }
        location.start()
        status = .loading(hasStations ? "Checking for new prices…" : "Fetching UK fuel prices…")
        do {
            let progress: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    if case .loading = self.status { self.status = .loading(message) }
                }
            }
            if let contents = try await repository.refresh(force: force, progress: progress) {
                apply(contents)
            }
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func cycleFuel() {
        let options = FuelType.pickerOptions
        let index = options.firstIndex(of: fuel) ?? -1
        fuel = options[(index + 1) % options.count]
    }

    func cycleRadius() {
        let options = Self.radiusOptions
        let index = options.firstIndex(of: radiusMiles) ?? -1
        radiusMiles = options[(index + 1) % options.count]
    }

    private func apply(_ contents: StationRepository.Contents) {
        stations = contents.stations
        updatedAt = contents.updatedAt
        hasStations = !stations.isEmpty
        recomputeResults()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func locationDidUpdate(_ newLocation: CLLocation) {
        // Re-sort only after a meaningful move; GPS jitter shouldn't reshuffle the list.
        if let resultsOrigin, newLocation.distance(from: resultsOrigin) < 200 { return }
        recomputeResults()
    }

    private func recomputeResults() {
        guard let here = location.location else {
            results = []
            notifyChange()
            return
        }
        resultsOrigin = here

        let radiusMetres = radiusMiles * 1609.344
        let oldest = Date().addingTimeInterval(-Self.maxPriceAge)
        results = stations.compactMap { station -> StationResult? in
            guard !station.isClosed,
                  let coordinate = station.coordinate,
                  let price = station.price(for: fuel) else { return nil }
            if let updated = price.updated, updated < oldest { return nil }
            let metres = here.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard metres <= radiusMetres else { return nil }
            return StationResult(station: station, price: price, miles: metres / 1609.344)
        }
        .sorted { ($0.price.pence, $0.miles) < ($1.price.pence, $1.miles) }

        notifyChange()
    }
}
