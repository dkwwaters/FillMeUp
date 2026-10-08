import Foundation

/// A fuel grade as reported by the Fuel Finder API.
///
/// Stored as the raw API code rather than a closed enum so that a new grade
/// appearing in the feed still shows up instead of being silently dropped.
struct FuelType: Hashable, Codable, Identifiable, Sendable {
    let code: String
    var id: String { code }

    init(_ code: String) {
        self.code = FuelType.normalise(code)
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    static let e10            = FuelType("E10")
    static let e5             = FuelType("E5")
    static let dieselStandard = FuelType("B7_STANDARD")
    static let dieselPremium  = FuelType("B7_PREMIUM")

    /// Grades offered in the fuel picker, most common first.
    static let pickerOptions: [FuelType] = [.e10, .e5, .dieselStandard, .dieselPremium]

    /// Folds the various spellings seen in the feed onto one code per grade.
    static func normalise(_ raw: String) -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
        switch code {
        case "B7", "DIESEL":              return "B7_STANDARD"
        case "SDV", "SUPER_DIESEL":       return "B7_PREMIUM"
        case "UNLEADED":                  return "E10"
        case "SUPER_UNLEADED":            return "E5"
        default:                          return code
        }
    }

    var name: String {
        switch code {
        case "E10":         return "Unleaded (E10)"
        case "E5":          return "Super Unleaded (E5)"
        case "B7_STANDARD": return "Diesel (B7)"
        case "B7_PREMIUM":  return "Premium Diesel"
        case "B10":         return "Diesel (B10)"
        case "HVO":         return "HVO Diesel"
        default:            return code.replacingOccurrences(of: "_", with: " ")
        }
    }

    var shortName: String {
        switch code {
        case "E10":         return "Unleaded"
        case "E5":          return "Super"
        case "B7_STANDARD": return "Diesel"
        case "B7_PREMIUM":  return "Prem. Diesel"
        default:            return name
        }
    }
}
