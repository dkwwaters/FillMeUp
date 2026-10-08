import Foundation
import CoreLocation

struct FuelPrice: Codable, Hashable, Sendable {
    let fuelType: FuelType
    /// Pence per litre, e.g. 139.9.
    let pence: Double
    let updated: Date?

    var formatted: String { String(format: "%.1fp", pence) }

    /// Converts whatever unit the feed used into pence per litre, rejecting
    /// values no UK forecourt would charge (feed errors, not bargains).
    static func pencePerLitre(from raw: Double) -> Double? {
        var value = raw
        if value < 10 {
            value *= 100        // pounds per litre, e.g. 1.399
        } else if value >= 1000 {
            value /= 10         // tenths of a penny, e.g. 1399
        }
        guard (50...500).contains(value) else { return nil }
        return (value * 10).rounded() / 10
    }
}

struct Station: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var brand: String?
    var address: String
    var postcode: String?
    var latitude: Double?
    var longitude: Double?
    var isClosed: Bool
    var prices: [FuelPrice]

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    var title: String { brand ?? name }

    /// Trading name when it adds something beyond the brand.
    var subtitle: String? {
        guard let brand, name.localizedCaseInsensitiveCompare(brand) != .orderedSame else { return nil }
        return name
    }

    func price(for fuel: FuelType) -> FuelPrice? {
        prices.first { $0.fuelType == fuel }
    }

    /// Adds or replaces prices, keeping whichever reading is newer.
    mutating func merge(prices incoming: [FuelPrice]) {
        for price in incoming {
            if let index = prices.firstIndex(where: { $0.fuelType == price.fuelType }) {
                if let existing = prices[index].updated, let new = price.updated, new < existing { continue }
                prices[index] = price
            } else {
                prices.append(price)
            }
        }
    }
}

extension String {
    /// "TESCO EXTRA" → "Tesco Extra", leaving short acronyms like "BP" alone.
    var prettifiedName: String {
        guard self == uppercased(), contains(where: \.isLetter) else { return self }
        return split(separator: " ").map { word -> String in
            if word.filter(\.isLetter).count <= 2 { return String(word) }
            return word.prefix(1) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
