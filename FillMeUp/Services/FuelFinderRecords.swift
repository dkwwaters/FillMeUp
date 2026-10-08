import Foundation

// Raw records as served by the Fuel Finder API (and passed through unchanged
// by the Fill Me Up proxy). Decoding is deliberately forgiving: the feed is
// young, numbers sometimes arrive as strings, and one malformed station must
// not cost us the other eight thousand.

/// A forecourt from `GET /api/v1/pfs`.
struct StationRecord: Decodable, Sendable {
    var nodeID: String
    var tradingName: String?
    var brandName: String?
    var isClosed: Bool
    var addressLines: [String]
    var postcode: String?
    var latitude: Double?
    var longitude: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let id = c.lenientString("node_id") else {
            throw DecodingError.keyNotFound(AnyCodingKey("node_id"), .init(codingPath: c.codingPath, debugDescription: "Station has no node_id"))
        }
        nodeID = id
        tradingName = c.lenientString("trading_name")
        brandName = c.lenientString("brand_name")
        isClosed = (c.lenientBool("temporary_closure") ?? false) || (c.lenientBool("permanent_closure") ?? false)

        let location = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("location"))
        addressLines = ["address_line_1", "address_line_2", "city"].compactMap { location?.lenientString($0) }
        postcode = location?.lenientString("postcode")
        latitude = location?.lenientDouble("latitude")
        longitude = location?.lenientDouble("longitude")
    }
}

/// A forecourt's prices from `GET /api/v1/pfs/fuel-prices`.
struct PriceRecord: Decodable, Sendable {
    var nodeID: String
    var tradingName: String?
    var prices: [FuelPrice]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let id = c.lenientString("node_id") else {
            throw DecodingError.keyNotFound(AnyCodingKey("node_id"), .init(codingPath: c.codingPath, debugDescription: "Price row has no node_id"))
        }
        nodeID = id
        tradingName = c.lenientString("trading_name")
        let entries = (try? c.decode(LossyArray<PriceEntry>.self, forKey: AnyCodingKey("fuel_prices")))?.elements ?? []
        prices = entries.compactMap(\.price)
    }

    private struct PriceEntry: Decodable {
        var price: FuelPrice?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let code = c.lenientString("fuel_type"),
                  let raw = c.lenientDouble("price"),
                  let pence = FuelPrice.pencePerLitre(from: raw) else {
                price = nil
                return
            }
            let updated = (c.lenientString("price_last_updated") ?? c.lenientString("price_change_effective_timestamp"))
                .flatMap(FeedDate.parse)
            price = FuelPrice(fuelType: FuelType(code), pence: pence, updated: updated)
        }
    }
}

extension Station {
    init(record: StationRecord) {
        let name = (record.tradingName ?? record.brandName ?? "Fuel station").prettifiedName
        self.init(
            id: record.nodeID,
            name: name,
            brand: record.brandName?.prettifiedName,
            address: record.addressLines.map(\.prettifiedName).joined(separator: ", "),
            postcode: record.postcode?.uppercased(),
            latitude: record.latitude,
            longitude: record.longitude,
            isClosed: record.isClosed,
            prices: []
        )
    }

    /// Refreshes details from a newer station record, keeping known prices.
    mutating func update(from record: StationRecord) {
        let prices = self.prices
        self = Station(record: record)
        self.prices = prices
    }
}

// MARK: - Response envelopes

/// A list of records, whether the API sent a bare array or wrapped it as
/// `{"data": [...]}` (or `{"data": {"data": [...]}}`, which has also been seen).
struct RecordList<Element: Decodable>: Decodable {
    var records: [Element]

    init(from decoder: Decoder) throws {
        if let list = try? LossyArray<Element>(from: decoder) {
            records = list.elements
            return
        }
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in ["data", "results", "items", "records"].map({ AnyCodingKey($0) }) where c.contains(key) {
            if let nested = try? c.decode(RecordList<Element>.self, forKey: key) {
                records = nested.records
                return
            }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Response held no list of records"))
    }
}

/// Decodes every element it can and skips the rest.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(SkippedValue.self)) == nil {
                break
            }
        }
        self.elements = elements
    }

    private struct SkippedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// The `message` an error response carries, if any.
struct APIMessage: Decodable {
    var message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        message = c.lenientString("message") ?? c.lenientString("error")
        if message == nil, let nested = try? c.decode(APIMessage.self, forKey: AnyCodingKey("data")) {
            message = nested.message
        }
    }

    static func extract(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(APIMessage.self, from: data), let message = decoded.message {
            return message
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Lenient decoding helpers

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func lenientString(_ key: String) -> String? {
        let key = AnyCodingKey(key)
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        return nil
    }

    func lenientDouble(_ key: String) -> Double? {
        let key = AnyCodingKey(key)
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return double }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func lenientBool(_ key: String) -> Bool? {
        let key = AnyCodingKey(key)
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int != 0 }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "true", "yes", "y", "1":  return true
            case "false", "no", "n", "0":  return false
            default:                       return nil
            }
        }
        return nil
    }
}

/// Timestamps in the formats the feed has been seen to use. Ones without a
/// zone are taken as UTC, matching the API's own query timestamps.
enum FeedDate {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()

    private static let local: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "dd/MM/yyyy HH:mm:ss",
        "dd/MM/yyyy HH:mm",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    static func parse(_ string: String) -> Date? {
        if let date = isoFractional.date(from: string) ?? iso.date(from: string) { return date }
        for formatter in local {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
