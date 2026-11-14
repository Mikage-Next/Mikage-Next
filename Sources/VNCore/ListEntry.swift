import Foundation

/// Where a game sits in the player's own list. The cases mirror the five
/// collection states Bangumi and VNDB share, so a status maps to both
/// services without loss.
public enum PlayStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case wish
    case playing
    case finished
    case onHold = "on-hold"
    case dropped

    public var id: String { rawValue }

    /// Bangumi collection type: 1 wish, 2 done, 3 doing, 4 on hold, 5 dropped.
    public var bangumiType: Int {
        switch self {
        case .wish: return 1
        case .finished: return 2
        case .playing: return 3
        case .onHold: return 4
        case .dropped: return 5
        }
    }

    /// VNDB's built-in list labels: 1 Playing, 2 Finished, 3 Stalled,
    /// 4 Dropped, 5 Wishlist.
    public var vndbLabel: Int {
        switch self {
        case .playing: return 1
        case .finished: return 2
        case .onHold: return 3
        case .dropped: return 4
        case .wish: return 5
        }
    }

    /// Every label a status can set; the others are cleared on each update so
    /// a VN never carries two of them.
    public static let vndbStatusLabels = [1, 2, 3, 4, 5]
}

/// The two metadata services a game can be linked to.
public enum MetadataService: String, Codable, CaseIterable, Identifiable, Sendable {
    case bangumi
    case vndb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bangumi: return "Bangumi"
        case .vndb: return "VNDB"
        }
    }
}

/// The player's own entry for a game: status, rating, comment and dates.
///
/// Kept separate from `GameLink` because it exists without a link too: a
/// status set on an unmatched game stays local and syncs once it is linked.
/// Playtime is not here; it stays in `GameRecord` and never leaves the device.
public struct ListEntry: Codable, Equatable, Sendable {
    public var status: PlayStatus?
    /// 1–10, the scale both services use (VNDB stores it ×10).
    public var rating: Int?
    public var comment: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Services with changes not yet written. Cleared per service on a
    /// successful sync, and kept across launches so nothing is lost offline.
    public var pendingSync: [MetadataService]
    public var lastSyncedAt: Date?

    public init(
        status: PlayStatus? = nil,
        rating: Int? = nil,
        comment: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        pendingSync: [MetadataService] = [],
        lastSyncedAt: Date? = nil
    ) {
        self.status = status
        self.rating = rating.map(Self.clampRating)
        self.comment = comment
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pendingSync = pendingSync
        self.lastSyncedAt = lastSyncedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decodeIfPresent(PlayStatus.self, forKey: .status)
        rating = (try? container.decodeIfPresent(Int.self, forKey: .rating)).map(Self.clampRating)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        pendingSync = (try? container.decodeIfPresent([MetadataService].self, forKey: .pendingSync)) ?? []
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    public var isEmpty: Bool {
        status == nil && rating == nil && (comment ?? "").isEmpty
            && startedAt == nil && finishedAt == nil
    }

    /// Marks the entry as changed for every service in `services`.
    public mutating func markPending(_ services: [MetadataService]) {
        for service in services where !pendingSync.contains(service) {
            pendingSync.append(service)
        }
    }

    public static func clampRating(_ value: Int) -> Int {
        min(max(value, 1), 10)
    }
}

/// A game's link to Bangumi and/or VNDB, with the details fetched from them.
public struct GameLink: Codable, Equatable, Sendable {
    /// VNDB id including its prefix, such as "v17".
    public var vndbID: String?
    public var bangumiID: Int?
    public var metadata: LinkedMetadata
    /// Downloaded artwork in the library's Covers folder.
    public var posterName: String?
    public var bannerName: String?
    /// Source URLs of the files above, so a refresh only downloads changes.
    public var posterSource: String?
    public var bannerSource: String?
    /// Card art the player picked from the services' images; overrides
    /// the automatic 16:9-then-4:3 choice.
    public var bannerChoice: String?
    /// No longer used: the details page always shows VNDB's cover. Kept
    /// so libraries saved by earlier builds still decode.
    public var posterChoice: String?
    /// The same work in the NextMoe catalog, which supplies the extra
    /// ratings and play lengths.
    public var nextmoeWorkID: String?

    public init(
        vndbID: String? = nil,
        bangumiID: Int? = nil,
        metadata: LinkedMetadata = LinkedMetadata(),
        posterName: String? = nil,
        bannerName: String? = nil,
        posterSource: String? = nil,
        bannerSource: String? = nil,
        bannerChoice: String? = nil,
        posterChoice: String? = nil,
        nextmoeWorkID: String? = nil
    ) {
        self.vndbID = vndbID
        self.bangumiID = bangumiID
        self.metadata = metadata
        self.posterName = posterName
        self.bannerName = bannerName
        self.posterSource = posterSource
        self.bannerSource = bannerSource
        self.bannerChoice = bannerChoice
        self.posterChoice = posterChoice
        self.nextmoeWorkID = nextmoeWorkID
    }

    public var services: [MetadataService] {
        var result: [MetadataService] = []
        if bangumiID != nil { result.append(.bangumi) }
        if vndbID != nil { result.append(.vndb) }
        return result
    }

    public var bangumiURL: URL? {
        bangumiID.map { BangumiNetwork.shared.webURL("subject/\($0)") }
    }

    public var vndbURL: URL? {
        vndbID.flatMap { URL(string: "https://vndb.org/\($0)") }
    }
}

/// An image a service offers, with whether it is marked as sensitive.
public struct ArtworkCandidate: Codable, Equatable, Sendable {
    public var url: String
    public var sensitive: Bool
    /// Width over height, when the service reports dimensions.
    public var aspectRatio: Double?
    /// An AI-upscaled or redrawn version of the art, which NextMoe offers
    /// for some covers; labelled as such wherever it can be picked.
    public var aiRedraw: Bool?

    public init(url: String, sensitive: Bool, aspectRatio: Double? = nil, aiRedraw: Bool? = nil) {
        self.url = url
        self.sensitive = sensitive
        self.aspectRatio = aspectRatio
        self.aiRedraw = aiRedraw
    }

    public var isAIRedraw: Bool { aiRedraw == true }
}

/// A service's community score for a game.
public struct CommunityRating: Codable, Equatable, Sendable {
    /// Out of 10.
    public var score: Double
    public var votes: Int
    /// Place in the service's ranking; nil while the game is unranked.
    public var rank: Int?

    public init(score: Double, votes: Int, rank: Int? = nil) {
        self.score = score
        self.votes = votes
        self.rank = rank
    }
}

/// How long a site's players say the game takes.
public struct PlayLength: Codable, Equatable, Sendable {
    /// NextMoe's source name: "vndb", "erogamescape", "howlongtobeat".
    public var source: String
    public var minutes: Int
    public var votes: Int

    public init(source: String, minutes: Int, votes: Int) {
        self.source = source
        self.minutes = minutes
        self.votes = votes
    }
}

/// Details merged from both services. Bangumi supplies the Chinese title,
/// synopsis and tags; VNDB supplies developer, release date and screenshots.
/// Each falls back to the other service when its preferred source has none.
public struct LinkedMetadata: Codable, Equatable, Sendable {
    /// Title in the original script, such as Japanese.
    public var originalTitle: String?
    /// VNDB's romanized main title.
    public var romanizedTitle: String?
    /// Bangumi's Chinese title.
    public var chineseTitle: String?
    public var developer: String?
    /// ISO date as the service gives it: "2019-08-23", "2019-08" or "2019".
    public var released: String?
    public var synopsis: String?
    public var synopsisSource: MetadataService?
    public var tags: [String]
    public var posters: [ArtworkCandidate]
    public var screenshots: [ArtworkCandidate]
    public var bangumiRating: CommunityRating?
    public var vndbRating: CommunityRating?
    /// From NextMoe, each converted to a score out of 10: ErogameScape
    /// (out of 100), DLsite (a store rating out of 5) and NextMoe itself.
    public var egsRating: CommunityRating?
    public var dlsiteRating: CommunityRating?
    public var nextmoeRating: CommunityRating?
    /// Play lengths NextMoe gathered from VNDB, ErogameScape and others.
    public var lengths: [PlayLength]
    public var officialSite: String?
    /// Ids on sites linked through NextMoe, for their pages.
    public var egsID: String?
    public var dlsiteID: String?
    public var nextmoePage: String?
    /// NextMoe's wide banner, often the game's key art, and its cover when
    /// that isn't VNDB's own cover again.
    public var nextmoeBanner: ArtworkCandidate?
    public var nextmoeCover: ArtworkCandidate?
    public var fetchedAt: Date?
    /// How the details were put together. Details from an older format are
    /// fetched again, since sensitivity flags and poster order changed.
    public var format: Int

    /// Format 2: VNDB's cover leads, and only explicit images count as
    /// sensitive (Bangumi's R18 flag marks the game, not its cover).
    /// Format 3: each service's community rating.
    /// Format 4: ratings, play lengths and links from NextMoe.
    /// Format 5: NextMoe's banner and cover.
    public static let currentFormat = 5

    public var isStale: Bool { format < Self.currentFormat }

    public init(
        originalTitle: String? = nil,
        romanizedTitle: String? = nil,
        chineseTitle: String? = nil,
        developer: String? = nil,
        released: String? = nil,
        synopsis: String? = nil,
        synopsisSource: MetadataService? = nil,
        tags: [String] = [],
        posters: [ArtworkCandidate] = [],
        screenshots: [ArtworkCandidate] = [],
        bangumiRating: CommunityRating? = nil,
        vndbRating: CommunityRating? = nil,
        egsRating: CommunityRating? = nil,
        dlsiteRating: CommunityRating? = nil,
        nextmoeRating: CommunityRating? = nil,
        lengths: [PlayLength] = [],
        officialSite: String? = nil,
        egsID: String? = nil,
        dlsiteID: String? = nil,
        nextmoePage: String? = nil,
        nextmoeBanner: ArtworkCandidate? = nil,
        nextmoeCover: ArtworkCandidate? = nil,
        fetchedAt: Date? = nil,
        format: Int = LinkedMetadata.currentFormat
    ) {
        self.originalTitle = originalTitle
        self.romanizedTitle = romanizedTitle
        self.chineseTitle = chineseTitle
        self.developer = developer
        self.released = released
        self.synopsis = synopsis
        self.synopsisSource = synopsisSource
        self.tags = tags
        self.posters = posters
        self.screenshots = screenshots
        self.bangumiRating = bangumiRating
        self.vndbRating = vndbRating
        self.egsRating = egsRating
        self.dlsiteRating = dlsiteRating
        self.nextmoeRating = nextmoeRating
        self.lengths = lengths
        self.officialSite = officialSite
        self.egsID = egsID
        self.dlsiteID = dlsiteID
        self.nextmoePage = nextmoePage
        self.nextmoeBanner = nextmoeBanner
        self.nextmoeCover = nextmoeCover
        self.fetchedAt = fetchedAt
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        romanizedTitle = try container.decodeIfPresent(String.self, forKey: .romanizedTitle)
        chineseTitle = try container.decodeIfPresent(String.self, forKey: .chineseTitle)
        developer = try container.decodeIfPresent(String.self, forKey: .developer)
        released = try container.decodeIfPresent(String.self, forKey: .released)
        synopsis = try container.decodeIfPresent(String.self, forKey: .synopsis)
        synopsisSource = try? container.decodeIfPresent(MetadataService.self, forKey: .synopsisSource)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        posters = try container.decodeIfPresent([ArtworkCandidate].self, forKey: .posters) ?? []
        screenshots = try container.decodeIfPresent([ArtworkCandidate].self, forKey: .screenshots) ?? []
        bangumiRating = try? container.decodeIfPresent(CommunityRating.self, forKey: .bangumiRating)
        vndbRating = try? container.decodeIfPresent(CommunityRating.self, forKey: .vndbRating)
        egsRating = try? container.decodeIfPresent(CommunityRating.self, forKey: .egsRating)
        dlsiteRating = try? container.decodeIfPresent(CommunityRating.self, forKey: .dlsiteRating)
        nextmoeRating = try? container.decodeIfPresent(CommunityRating.self, forKey: .nextmoeRating)
        lengths = (try? container.decodeIfPresent([PlayLength].self, forKey: .lengths)) ?? []
        officialSite = try? container.decodeIfPresent(String.self, forKey: .officialSite)
        egsID = try? container.decodeIfPresent(String.self, forKey: .egsID)
        dlsiteID = try? container.decodeIfPresent(String.self, forKey: .dlsiteID)
        nextmoePage = try? container.decodeIfPresent(String.self, forKey: .nextmoePage)
        nextmoeBanner = try? container.decodeIfPresent(ArtworkCandidate.self, forKey: .nextmoeBanner)
        nextmoeCover = try? container.decodeIfPresent(ArtworkCandidate.self, forKey: .nextmoeCover)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        format = (try? container.decodeIfPresent(Int.self, forKey: .format)) ?? 1
    }

    /// The four-digit year of `released`, if it has one.
    public var releaseYear: String? {
        guard let released, released.count >= 4 else { return nil }
        let year = String(released.prefix(4))
        return Int(year) == nil ? nil : year
    }

    /// The first poster, skipping sensitive ones when asked.
    public func poster(hidingSensitive: Bool) -> ArtworkCandidate? {
        posters.first { !hidingSensitive || !$0.sensitive }
    }

    /// Art for library cards and the continue hero: the first landscape
    /// image, 16:9 before 4:3 before other wide shapes, skipping sensitive
    /// ones when asked. Nil when no image is known to be landscape, so the
    /// cards fall back to the poster.
    /// NextMoe's banner comes first when it is landscape: it is often the
    /// game's key art rather than a scene. AI redraws are never picked by
    /// themselves, only when the player chooses one.
    public func banner(hidingSensitive: Bool) -> ArtworkCandidate? {
        if let banner = nextmoeBanner, Self.cardRank(banner) <= 2, !banner.isAIRedraw,
           !(hidingSensitive && banner.sensitive) {
            return banner
        }
        return cardArt(hidingSensitive: hidingSensitive).first { Self.cardRank($0) <= 2 && !$0.isAIRedraw }
    }

    /// Every image the services offer, best card art first: 16:9, then
    /// 4:3, other landscape shapes, unknown sizes, then portrait covers.
    /// At the same rank NextMoe's banner leads, then screenshots, then
    /// posters, then NextMoe's cover.
    public func cardArt(hidingSensitive: Bool) -> [ArtworkCandidate] {
        var seen = Set<String>()
        let nextmoeBanner = nextmoeBanner.map { [$0] } ?? []
        let nextmoeCover = nextmoeCover.map { [$0] } ?? []
        return (nextmoeBanner + screenshots + posters + nextmoeCover)
            .filter { (!hidingSensitive || !$0.sensitive) && seen.insert($0.url).inserted }
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (Self.cardRank(lhs.element), Self.cardRank(rhs.element))
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public static func cardRank(_ candidate: ArtworkCandidate) -> Int {
        guard let aspect = candidate.aspectRatio else { return 3 }
        if abs(aspect - 16.0 / 9.0) < 0.1 { return 0 }
        if abs(aspect - 4.0 / 3.0) < 0.08 { return 1 }
        if aspect >= 1.2 { return 2 }
        return 4
    }

    /// Combines details from the two services by the preference above.
    /// `vndbRank` comes from a separate count query; VNDB returns no rank.
    public static func merged(
        vndb: VNDBVisualNovel?,
        bangumi: BangumiSubject?,
        vndbRank: Int? = nil,
        fetchedAt: Date = Date()
    ) -> LinkedMetadata {
        var result = LinkedMetadata(fetchedAt: fetchedAt)
        result.originalTitle = vndb?.originalTitle ?? bangumi?.name.nonEmpty
        result.romanizedTitle = vndb?.title.nonEmpty
        result.chineseTitle = bangumi?.nameCN?.nonEmpty ?? vndb?.title(inLanguagePrefix: "zh")
        result.developer = vndb?.developerNames ?? bangumi?.infoboxValue(for: ["开发", "开发商", "制作", "品牌"])
        result.released = vndb?.released.flatMap(Self.isoDate) ?? bangumi?.date?.nonEmpty
        if let summary = bangumi?.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            result.synopsis = summary
            result.synopsisSource = .bangumi
        } else if let description = vndb?.plainDescription, !description.isEmpty {
            result.synopsis = description
            result.synopsisSource = .vndb
        }
        let bangumiTags = bangumi?.topTags(limit: 6) ?? []
        result.tags = bangumiTags.isEmpty ? (vndb?.topTags(limit: 6) ?? []) : bangumiTags
        // VNDB's cover leads, with its own sensitivity rating; Bangumi's
        // package art follows. Bangumi's R18 flag describes the game rather
        // than the cover, which is the same art sold in shops.
        if let image = vndb?.image {
            result.posters.append(image.candidate)
        }
        if let poster = bangumi?.posterURL {
            result.posters.append(ArtworkCandidate(url: poster, sensitive: false))
        }
        result.screenshots = vndb?.screenshots.map(\.candidate) ?? []
        result.bangumiRating = bangumi?.communityRating
        result.vndbRating = vndb?.communityRating(rank: vndbRank)
        return result
    }

    /// Adds what NextMoe knows beyond the two services: the other sites'
    /// ratings, play lengths, links, and a Chinese title when neither
    /// service has one (machine translations are skipped).
    public mutating func apply(nextmoe work: NextMoeWork) {
        func rating(_ source: String, scale: Double) -> CommunityRating? {
            work.rating(source).map {
                CommunityRating(score: ($0.score ?? 0) * scale, votes: $0.voteCount ?? 0, rank: $0.rank)
            }
        }
        egsRating = rating("erogamescape", scale: 0.1)
        dlsiteRating = rating("dlsite", scale: 2)
        nextmoeRating = rating("nextmoe", scale: 1)
        lengths = (work.playtimes ?? []).compactMap { time in
            guard let minutes = time.minutes, minutes > 0 else { return nil }
            return PlayLength(source: time.source, minutes: minutes, votes: time.voteCount ?? 0)
        }
        officialSite = work.officialSite
        egsID = work.ref("erogamescape")
        dlsiteID = work.ref("dlsite")
        nextmoePage = work.pageURL
        nextmoeBanner = work.banner?.candidate
        // A cover taken from VNDB is the one VNDB already supplies. NextMoe
        // serves its own copy, which is quicker to reach from mainland
        // China than VNDB's image host, so that copy is downloaded instead.
        if let cover = work.cover, cover.source == "vndb" {
            nextmoeCover = nil
            if let index = posters.firstIndex(where: { $0.url.contains("vndb.org") }) {
                posters[index].url = cover.url
            }
        } else {
            nextmoeCover = work.cover?.candidate
        }
        if chineseTitle == nil {
            chineseTitle = work.chineseTitle
        }
    }

    /// Keeps the NextMoe details of `older` when they couldn't be fetched
    /// this time.
    public mutating func keepNextMoe(from older: LinkedMetadata) {
        egsRating = older.egsRating
        dlsiteRating = older.dlsiteRating
        nextmoeRating = older.nextmoeRating
        lengths = older.lengths
        officialSite = older.officialSite
        egsID = older.egsID
        dlsiteID = older.dlsiteID
        nextmoePage = older.nextmoePage
        nextmoeBanner = older.nextmoeBanner
        nextmoeCover = older.nextmoeCover
    }

    /// The length to show: the most-voted of VNDB and HowLongToBeat, else
    /// ErogameScape's, which comes without a vote count.
    public var typicalLength: PlayLength? {
        let voted = lengths.filter { ["vndb", "howlongtobeat"].contains($0.source) && $0.votes > 0 }
        return voted.max { $0.votes < $1.votes }
            ?? lengths.first { $0.source == "erogamescape" }
            ?? lengths.first
    }

    public var egsURL: URL? {
        egsID.flatMap { URL(string: "https://erogamescape.dyndns.org/~ap2/ero/toukei_kaiseki/game.php?game=\($0)") }
    }

    /// DLsite keeps all-ages works under "pro" (VJ…) and adult ones under
    /// "maniax" (RJ…).
    public var dlsiteURL: URL? {
        guard let id = dlsiteID else { return nil }
        let floor = id.hasPrefix("VJ") ? "pro" : "maniax"
        return URL(string: "https://www.dlsite.com/\(floor)/work/=/product_id/\(id).html")
    }

    public var nextmoeURL: URL? {
        nextmoePage.flatMap(URL.init(string:))
    }

    public var officialSiteURL: URL? {
        officialSite.flatMap(URL.init(string:))
    }

    /// VNDB uses "TBA" and other placeholders for unknown dates.
    private static func isoDate(_ value: String) -> String? {
        guard let first = value.first, first.isNumber else { return nil }
        return value
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
