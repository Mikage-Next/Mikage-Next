import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A work in the NextMoe catalog (鲲 Galgame 论坛), which lines up the ids
/// that VNDB, Bangumi, ErogameScape, DLsite and others give the same game,
/// and gathers their ratings and play lengths.
public struct NextMoeWork: Decodable, Equatable, Sendable {
    public struct Localized: Decodable, Equatable, Sendable {
        public var value: String
        /// True for machine-translated titles, which Mikage never shows.
        public var isMachine: Bool?
    }

    public struct Ref: Decodable, Equatable, Sendable {
        public var source: String
        public var externalId: String
    }

    public struct Rating: Decodable, Equatable, Sendable {
        public var source: String
        /// On the site's own scale: ErogameScape out of 100, DLsite out
        /// of 5, the others out of 10.
        public var score: Double?
        public var voteCount: Int?
        public var rank: Int?
    }

    public struct Playtime: Decodable, Equatable, Sendable {
        public var source: String
        public var minutes: Int?
        public var voteCount: Int?
    }

    public struct Link: Decodable, Equatable, Sendable {
        public var source: String
        public var url: String
    }

    public struct Claim: Decodable, Equatable, Sendable {
        public var site: String?
        public var siteWorkId: String?
    }

    public var id: String
    public var displayName: String
    public var localized: [String: Localized]?
    public var releaseDate: String?
    public var refs: [Ref]?
    public var ratings: [Rating]?
    public var playtimes: [Playtime]?
    public var links: [Link]?
    public var claim: Claim?

    public init(
        id: String,
        displayName: String,
        localized: [String: Localized]? = nil,
        releaseDate: String? = nil,
        refs: [Ref]? = nil,
        ratings: [Rating]? = nil,
        playtimes: [Playtime]? = nil,
        links: [Link]? = nil,
        claim: Claim? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.localized = localized
        self.releaseDate = releaseDate
        self.refs = refs
        self.ratings = ratings
        self.playtimes = playtimes
        self.links = links
        self.claim = claim
    }

    /// The first id the work has on `source`.
    public func ref(_ source: String) -> String? {
        refs?.first { $0.source == source }?.externalId.nonEmpty
    }

    /// The VNDB novel id, such as "v17". Refs also list VNDB release ids
    /// ("r…"), which are skipped.
    public var vndbID: String? {
        refs?.first { $0.source == "vndb" && $0.externalId.hasPrefix("v") }?.externalId
    }

    /// Bangumi subjects for the work; usually one.
    public var bangumiIDs: [Int] {
        (refs ?? []).filter { $0.source == "bangumi" }.compactMap { Int($0.externalId) }
    }

    public var alignment: NextMoeAlignment {
        NextMoeAlignment(workID: id, vndbID: vndbID, bangumiIDs: bangumiIDs)
    }

    /// The human-written Simplified Chinese title, if there is one.
    public var chineseTitle: String? {
        guard let title = localized?["zh-Hans"], title.isMachine != true else { return nil }
        return title.value.nonEmpty
    }

    public func rating(_ source: String) -> Rating? {
        ratings?.first { $0.source == source && ($0.score ?? 0) > 0 && ($0.voteCount ?? 0) > 0 }
    }

    /// The game's page on 鲲 Galgame, where its NextMoe ratings come from.
    public var pageURL: String? {
        guard claim?.site == "kungal" else { return nil }
        return "https://www.kungal.com/galgame/\(claim?.siteWorkId ?? id)"
    }

    /// The official site among the work's links. Ports and store pages are
    /// listed as official sites too; the shortest address is usually the
    /// game's own home page.
    public var officialSite: String? {
        (links ?? [])
            .filter { $0.source == "official_site" && $0.url.hasPrefix("http") }
            .map(\.url)
            .min { $0.count < $1.count }
    }
}

/// Which VNDB and Bangumi entries NextMoe says are one work.
public struct NextMoeAlignment: Equatable, Sendable {
    public var workID: String
    public var vndbID: String?
    public var bangumiIDs: [Int]

    public init(workID: String, vndbID: String?, bangumiIDs: [Int]) {
        self.workID = workID
        self.vndbID = vndbID
        self.bangumiIDs = bangumiIDs
    }

    public func contains(vndb id: String?) -> Bool {
        id != nil && vndbID == id
    }

    public func contains(bangumi id: Int?) -> Bool {
        id.map(bangumiIDs.contains) ?? false
    }
}

public enum NextMoeError: LocalizedError, Equatable {
    case rateLimited
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            return String(localized: "NextMoe is busy. Try again in a minute.")
        case .http(let code, let message):
            return message.isEmpty
                ? String(localized: "NextMoe returned error \(code).")
                : String(localized: "NextMoe returned error \(code): \(message)")
        case .invalidResponse:
            return String(localized: "NextMoe sent a response Mikage couldn’t read.")
        }
    }
}

/// Client for the public NextMoe catalog. Reading it needs no account or
/// key; the service limits requests per address, so every call waits its
/// turn at `NextMoeGate`.
public struct NextMoeClient: Sendable {
    public static let baseURL = URL(string: "https://api.nextmoe.dev/v2/catalog")!
    /// The most ids one lookup takes.
    public static let lookupLimit = 100

    private let session: URLSession
    private let gate: NextMoeGate

    public init(session: URLSession = .shared, gate: NextMoeGate = .shared) {
        self.session = session
        self.gate = gate
    }

    /// Works whose titles match `query`, Chinese titles included.
    public func search(_ query: String, limit: Int = 10) async throws -> [NextMoeWork] {
        try await list([
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "include", value: "refs")
        ]).items
    }

    /// The works behind ids such as "vndb:v17" or "bangumi:3154", with
    /// ratings and play lengths. Ids NextMoe doesn't know are left out.
    public func works(refs: [String]) async throws -> [NextMoeWork] {
        guard !refs.isEmpty else { return [] }
        var result: [NextMoeWork] = []
        var start = 0
        while start < refs.count {
            let chunk = refs[start..<min(start + Self.lookupLimit, refs.count)]
            result += try await list([
                URLQueryItem(name: "refs", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "view", value: "full"),
                URLQueryItem(name: "include", value: "playtimes")
            ]).items
            start += Self.lookupLimit
        }
        return result
    }

    /// The work for one VNDB or Bangumi entry.
    public func work(vndbID: String?, bangumiID: Int?) async throws -> NextMoeWork? {
        let refs = [vndbID.map { "vndb:\($0)" }, bangumiID.map { "bangumi:\($0)" }].compactMap { $0 }
        let works = try await works(refs: refs)
        return works.first { $0.vndbID == vndbID && vndbID != nil }
            ?? works.first { $0.alignment.contains(bangumi: bangumiID) }
            ?? works.first
    }

    /// One work with its links (official site and others). A work merged
    /// into another is followed to the one it became.
    public func work(id: String) async throws -> NextMoeWork? {
        var id = id
        for _ in 0..<2 {
            let url = Self.baseURL.appendingPathComponent("works").appendingPathComponent(id)
            let (data, status) = try await get(url, query: [
                URLQueryItem(name: "include", value: "refs,ratings,playtimes,links")
            ])
            switch status {
            case 200..<300:
                return try decode(NextMoeWork.self, from: data)
            case 404:
                guard let problem = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      problem["code"] as? String == "ENTITY_MERGED",
                      let current = Self.string(problem["current_id"]) else { return nil }
                id = current
            default:
                throw NextMoeError.http(status, Self.message(in: data))
            }
        }
        return nil
    }

    // MARK: Requests

    private struct Page: Decodable {
        var items: [NextMoeWork]
        var missing: [String]?
    }

    private func list(_ query: [URLQueryItem]) async throws -> Page {
        let (data, status) = try await get(Self.baseURL.appendingPathComponent("works"), query: query)
        guard (200..<300).contains(status) else {
            throw NextMoeError.http(status, Self.message(in: data))
        }
        return try decode(Page.self, from: data)
    }

    private func get(_ url: URL, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Without nsfw=true, adult works come back as missing.
        components.queryItems = query + [URLQueryItem(name: "nsfw", value: "true")]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(MetadataHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        try await gate.wait()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextMoeError.invalidResponse }
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            await gate.pause(for: retry)
            throw NextMoeError.rateLimited
        }
        return (data, http.statusCode)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NextMoeError.invalidResponse
        }
    }

    /// Errors are RFC 9457 problem documents.
    private static func message(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["detail", "title", "code"] {
            if let text = object[key] as? String, !text.isEmpty {
                return String(text.prefix(200))
            }
        }
        return ""
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        return nil
    }
}

/// Spaces NextMoe requests out to stay inside the documented limit of 30
/// a minute per address, and holds them all back after a 429.
public actor NextMoeGate {
    public static let shared = NextMoeGate()

    private let interval: TimeInterval
    private var nextSlot = Date.distantPast
    private var pausedUntil = Date.distantPast

    public init(interval: TimeInterval = 2) {
        self.interval = interval
    }

    /// Waits for the next free slot; fails at once while paused.
    func wait() async throws {
        let now = Date()
        guard now >= pausedUntil else { throw NextMoeError.rateLimited }
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    func pause(for seconds: TimeInterval) {
        pausedUntil = max(pausedUntil, Date().addingTimeInterval(min(max(seconds, 1), 3600)))
    }
}
