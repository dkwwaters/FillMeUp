import CarPlay
import UIKit

/// CarPlay shows the same cheapest-first list as the phone. Tapping a station
/// starts directions in whichever navigation app the user last picked on the
/// phone (Apple Maps until they pick one).
///
/// Needs the com.apple.developer.carplay-fueling entitlement, which Apple
/// grants on request; see README.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// CarPlay is for glancing at while parked or stopped; keep the list short.
    private static let maxRows = 12

    private var scene: CPTemplateApplicationScene?
    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var observer: NSObjectProtocol?

    private var model: FuelModel { FuelModel.shared }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        scene = templateApplicationScene
        self.interfaceController = interfaceController

        let template = CPListTemplate(title: "Fill Me Up", sections: [])
        listTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        observer = NotificationCenter.default.addObserver(forName: FuelModel.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        Task { await model.start() }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        listTemplate = nil
        self.interfaceController = nil
        scene = nil
    }

    private func reload() {
        guard let listTemplate else { return }

        listTemplate.leadingNavigationBarButtons = [
            CPBarButton(title: model.fuel.shortName) { [weak self] _ in self?.model.cycleFuel() }
        ]
        listTemplate.trailingNavigationBarButtons = [
            CPBarButton(title: "\(Int(model.radiusMiles)) mi") { [weak self] _ in self?.model.cycleRadius() }
        ]

        let rowLimit = min(Self.maxRows, CPListTemplate.maximumItemCount)
        let items: [CPListItem] = model.results.prefix(rowLimit).map { result in
            let item = CPListItem(
                text: "\(result.price.formatted)  \(result.station.title)",
                detailText: [result.distanceText, result.station.address].filter { !$0.isEmpty }.joined(separator: " · ")
            )
            item.handler = { [weak self] _, completion in
                self?.navigate(to: result)
                completion()
            }
            return item
        }

        let header = "\(model.fuel.name) within \(Int(model.radiusMiles)) miles"
        listTemplate.updateSections(items.isEmpty ? [] : [CPListSection(items: items, header: header, sectionIndexTitle: nil)])

        let (title, subtitle) = emptyMessage
        listTemplate.emptyViewTitleVariants = [title]
        listTemplate.emptyViewSubtitleVariants = [subtitle]
    }

    private var emptyMessage: (String, String) {
        if !model.isConfigured {
            return ("Not set up", "Fill Me Up has no price source configured.")
        }
        if !model.location.isAuthorized {
            return ("Location needed", "Open Fill Me Up on your iPhone to allow location access.")
        }
        if case .loading(let message) = model.status, !model.hasStations {
            return ("Getting prices", message)
        }
        if case .failed(let message) = model.status, !model.hasStations {
            return ("Couldn't get prices", message)
        }
        if model.location.location == nil {
            return ("Finding your location", "")
        }
        return ("No \(model.fuel.shortName.lowercased()) nearby", "Tap \(Int(model.radiusMiles)) mi to search further.")
    }

    private func navigate(to result: StationResult) {
        guard let coordinate = result.station.coordinate, let scene else { return }
        let app = model.navigationApp
        scene.open(app.carPlayURL(to: coordinate), options: nil) { opened in
            // Google Maps or Waze may not be installed; fall back to Apple Maps.
            guard !opened, app != .appleMaps else { return }
            DispatchQueue.main.async {
                scene.open(NavigationApp.appleMaps.carPlayURL(to: coordinate), options: nil, completionHandler: nil)
            }
        }
    }
}
