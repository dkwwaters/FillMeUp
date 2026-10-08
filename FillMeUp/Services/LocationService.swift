import Foundation
import CoreLocation
import Observation

/// Asks for "while using" location access and keeps track of where the user is.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    private(set) var failed = false

    /// Called on every new fix, so non-SwiftUI code (the model, CarPlay) can react.
    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
        authorization = manager.authorizationStatus
    }

    /// Prompts for access the first time, then starts following the user.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            failed = false
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.failed = false
            self.location = latest
            self.onUpdate?(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // "Location unknown" is transient; Core Location keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in self.failed = true }
    }
}
