import Foundation

enum FuelDataError: LocalizedError {
    case notConfigured
    case badCredentials(String?)
    case http(status: Int, message: String?)
    case offline

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Fill Me Up hasn't been set up with a fuel price source yet."
        case .badCredentials(let message):
            return "The Fuel Finder service rejected the app's credentials." + (message.map { " (\($0))" } ?? "")
        case .http(let status, let message):
            return "The fuel price service returned an error (\(status))." + (message.map { " \($0)" } ?? "")
        case .offline:
            return "You appear to be offline."
        }
    }
}

/// Talks to the GOV.UK Fuel Finder API directly using the app's OAuth client
/// credentials. The API has no location search, so every station is pulled
/// down in batches and filtered on the device.
actor FuelFinderClient {
    struct Credentials: Sendable {
        let clientID: String
        let clientSecret: String
    }

    static let liveHost = "www.fuel-finder.service.gov.uk"

    /// The API allows 100 requests a minute, one at a time. Stay under it.
    private static let minimumRequestGap: TimeInterval = 0.75
    private static let maxBatches = 100

    private let credentials: Credentials
    private let baseURL: String
    private let session: URLSession
    private var accessToken: (value: String, expires: Date)?
    private var refreshToken: String?
    private var lastRequestAt: Date?

    /// `host` lets test-environment credentials target the test service.
    init(credentials: Credentials, host: String = FuelFinderClient.liveHost, session: URLSession = .shared) {
        self.credentials = credentials
        self.baseURL = "https://\(host)"
        self.session = session
    }

    func stations(since: Date?, onPage: @Sendable (Int) -> Void) async throws -> [StationRecord] {
        try await allPages(of: "/api/v1/pfs", since: since, onPage: onPage)
    }

    func prices(since: Date?, onPage: @Sendable (Int) -> Void) async throws -> [PriceRecord] {
        try await allPages(of: "/api/v1/pfs/fuel-prices", since: since, onPage: onPage)
    }

    // MARK: - Paging

    private func allPages<Record: Decodable>(of path: String, since: Date?, onPage: @Sendable (Int) -> Void) async throws -> [Record] {
        var records: [Record] = []
        var previousPage: Data?

        pages: for batch in 1...Self.maxBatches {
            onPage(batch)
            var query = [URLQueryItem(name: "batch-number", value: String(batch))]
            if let since {
                query.append(URLQueryItem(name: "effective-start-timestamp", value: Self.timestamp(since)))
            }

            let data: Data
            do {
                data = try await get(path, query: query)
            } catch let FuelDataError.http(status, message) {
                // The API signals "no more pages" with a 404 or a message
                // rather than an empty list. A 404 on the very first page of
                // a full download is a real error though.
                let exhausted = message?.localizedCaseInsensitiveContains("no more data") == true
                if exhausted || (status == 404 && (batch > 1 || since != nil)) { break pages }
                throw FuelDataError.http(status: status, message: message)
            }

            // Some deployments return the last page again rather than ending.
            if data == previousPage { break }
            previousPage = data

            let page = try JSONDecoder().decode(RecordList<Record>.self, from: data).records
            if page.isEmpty { break }
            records += page
        }
        return records
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Requests

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: baseURL + path)!
        components.queryItems = query
        let url = components.url!

        var rateLimitRetries = 0
        var retriedAuth = false
        while true {
            let token = try await validAccessToken()
            try await pace()

            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await send(request)

            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                // Tokens are sometimes revoked mid-download; get a fresh one once.
                guard !retriedAuth else { throw FuelDataError.badCredentials(APIMessage.extract(from: data)) }
                retriedAuth = true
                accessToken = nil
            case 429 where rateLimitRetries < 4:
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = min(retryAfter ?? 5 * pow(2, Double(rateLimitRetries)), 60)
                rateLimitRetries += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            default:
                throw FuelDataError.http(status: response.statusCode, message: APIMessage.extract(from: data))
            }
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expires > Date() { return accessToken.value }

        if let refreshToken,
           let renewed = try? await requestToken(path: "/api/v1/oauth/regenerate_access_token",
                                                 body: ["client_id": credentials.clientID, "refresh_token": refreshToken]) {
            return store(renewed)
        }

        let fresh = try await requestToken(path: "/api/v1/oauth/generate_access_token",
                                           body: ["client_id": credentials.clientID, "client_secret": credentials.clientSecret],
                                           standardForm: ["grant_type": "client_credentials", "scope": "fuelfinder.read"])
        return store(fresh)
    }

    private func store(_ token: TokenPayload) -> String {
        // Renew a minute early so a token never expires mid-request.
        let lifetime = max(token.expiresIn ?? 3600, 120) - 60
        accessToken = (token.accessToken, Date().addingTimeInterval(lifetime))
        if let refresh = token.refreshToken { refreshToken = refresh }
        return token.accessToken
    }

    /// Asks for a token with a JSON body, which the live service accepts.
    /// If that's refused and `standardForm` is given, retries as a standard
    /// OAuth form post (what the developer portal documents) with those extra fields.
    private func requestToken(path: String, body: [String: String], standardForm: [String: String]? = nil) async throws -> TokenPayload {
        try await pace()
        var request = URLRequest(url: URL(string: baseURL + path)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        var (data, response) = try await send(request)
        if let standardForm, [400, 415, 422].contains(response.statusCode) {
            var form = URLComponents()
            form.queryItems = body.merging(standardForm) { current, _ in current }
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // URLComponents leaves "+" alone, which a form decoder would read as a space.
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            try await pace()
            (data, response) = try await send(request)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = APIMessage.extract(from: data)
            if [400, 401, 403].contains(response.statusCode) { throw FuelDataError.badCredentials(message) }
            throw FuelDataError.http(status: response.statusCode, message: message)
        }
        return try JSONDecoder().decode(TokenPayload.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FuelDataError.http(status: 0, message: nil) }
            return (data, http)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw FuelDataError.offline
        }
    }

    private func pace() async throws {
        if let lastRequestAt {
            let wait = Self.minimumRequestGap - Date().timeIntervalSince(lastRequestAt)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lastRequestAt = Date()
    }
}

/// OAuth token response, either bare or wrapped in `{"success": true, "data": {...}}`.
private struct TokenPayload: Decodable {
    var accessToken: String
    var expiresIn: Double?
    var refreshToken: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        if let wrapped = try? c.decode(TokenPayload.self, forKey: AnyCodingKey("data")) {
            self = wrapped
            return
        }
        guard let token = c.lenientString("access_token") else {
            throw FuelDataError.badCredentials(c.lenientString("message"))
        }
        accessToken = token
        expiresIn = c.lenientDouble("expires_in")
        refreshToken = c.lenientString("refresh_token")
    }
}
