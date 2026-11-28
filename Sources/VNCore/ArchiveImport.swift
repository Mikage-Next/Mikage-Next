import Foundation

// Importing a game from a ZIP, RAR or 7z archive: reading the file list,
// finding the game's folder and the engine before anything is extracted, and
// finding the archives sitting in Documents. Reading and extracting the
// archives themselves is done by the app.

public enum ArchiveFormat: String, Sendable {
    case zip, rar, sevenZip

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7z"
        }
    }

    /// Whether names may be stored in a local code page (only ZIP).
    public var hasLegacyNames: Bool { self == .zip }

    /// The format a file name says, including the parts of a split archive
    /// (`.part1.rar`, `.7z.001`, `.z01`); nil for any other file.
    public init?(fileName: String) {
        guard let parsed = ArchiveFileName(fileName) else { return nil }
        self = parsed.format
    }
}

/// One file or folder in an archive, as its file list shows it.
public struct ArchiveEntry: Sendable, Equatable {
    /// The name as stored (ZIP) or as UTF-8 (RAR and 7z).
    public var rawName: [UInt8]
    /// Set when the format stores Unicode names (RAR and 7z).
    public var unicodeName: String?
    /// Uncompressed size; 0 for folders.
    public var size: Int64
    public var isDirectory: Bool
    public var isEncrypted: Bool
    /// Symbolic and hard links are never extracted.
    public var isLink: Bool

    public init(
        rawName: [UInt8],
        unicodeName: String? = nil,
        size: Int64 = 0,
        isDirectory: Bool = false,
        isEncrypted: Bool = false,
        isLink: Bool = false
    ) {
        self.rawName = rawName
        self.unicodeName = unicodeName
        self.size = size
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
        self.isLink = isLink
    }
}

public struct ArchiveListing: Sendable {
    public var format: ArchiveFormat
    public var entries: [ArchiveEntry]
    /// The sum of the part files on disk.
    public var archiveSize: Int64
    public var hasEncryptedEntries: Bool { entries.contains(where: \.isEncrypted) }

    public init(format: ArchiveFormat, entries: [ArchiveEntry], archiveSize: Int64) {
        self.format = format
        self.entries = entries
        self.archiveSize = archiveSize
    }
}

public enum ArchiveNameEncoding: String, CaseIterable, Sendable {
    case automatic, utf8, shiftJIS, gbk, big5
}

// MARK: - Names

/// Reading and cleaning the names in an archive.
public enum ArchiveNames {
    /// Foundation's code for the legacy encodings; the values are
    /// `CFStringConvertEncodingToNSStringEncoding` of GB 18030 (a GBK
    /// superset) and Big5, written out so this also builds without CoreFoundation.
    private static func foundationEncoding(_ encoding: ArchiveNameEncoding) -> String.Encoding {
        switch encoding {
        case .automatic, .utf8: return .utf8
        case .shiftJIS: return .shiftJIS
        case .gbk: return String.Encoding(rawValue: 0x8000_0632)
        case .big5: return String.Encoding(rawValue: 0x8000_0A03)
        }
    }

    private static func isASCII(_ bytes: [UInt8]) -> Bool {
        bytes.allSatisfy { $0 < 0x80 }
    }

    /// The bytes read in `encoding`, or nil when they are not valid text in
    /// it. Replacement characters and private-use characters count as invalid:
    /// a wrong code page often produces them.
    private static func strictDecode(_ bytes: [UInt8], as encoding: ArchiveNameEncoding) -> String? {
        guard let text = String(data: Data(bytes), encoding: foundationEncoding(encoding)) else { return nil }
        for scalar in text.unicodeScalars where scalar.value == 0xFFFD || (0xE000...0xF8FF).contains(scalar.value) {
            return nil
        }
        return text
    }

    /// The entry's name read with `encoding` (never `.automatic`), and whether
    /// it reads as text. A name the format stores as Unicode ignores
    /// `encoding`. An unreadable name is returned with replacement
    /// characters.
    public static func decode(_ entry: ArchiveEntry, as encoding: ArchiveNameEncoding) -> (name: String, readable: Bool) {
        if let unicode = entry.unicodeName {
            return (unicode.precomposedStringWithCanonicalMapping, !unicode.contains("\u{FFFD}"))
        }
        if isASCII(entry.rawName) {
            return (String(decoding: entry.rawName, as: UTF8.self), true)
        }
        if let text = strictDecode(entry.rawName, as: encoding) {
            return (text.precomposedStringWithCanonicalMapping, true)
        }
        return (String(decoding: entry.rawName, as: UTF8.self).precomposedStringWithCanonicalMapping, false)
    }

    /// The encoding the names read best in: UTF-8 when every name is valid
    /// UTF-8, else the one of Shift-JIS, GBK and Big5 that fails on the
    /// fewest names, with ties decided by which script the text looks like.
    public static func detect(_ entries: [ArchiveEntry]) -> ArchiveNameEncoding {
        let local = entries.filter { $0.unicodeName == nil && !isASCII($0.rawName) }
        if local.allSatisfy({ strictDecode($0.rawName, as: .utf8) != nil }) { return .utf8 }

        let candidates: [ArchiveNameEncoding] = [.shiftJIS, .gbk, .big5]
        let failures = candidates.map { encoding in
            local.filter { strictDecode($0.rawName, as: encoding) == nil }.count
        }
        let fewest = failures.min() ?? 0
        let finalists = candidates.indices.filter { failures[$0] == fewest }.map { candidates[$0] }

        var best = finalists[0]
        var bestScore = Int.min
        for encoding in finalists {
            let score = local.reduce(0) { $0 + scriptScore(decode($1, as: encoding).name) }
            if score > bestScore {
                best = encoding
                bestScore = score
            }
        }
        return best
    }

    /// How much a name looks like real Japanese or Chinese text.
    private static func scriptScore(_ name: String) -> Int {
        var score = 0
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: score += 2
            case 0x4E00...0x9FFF: score += 1
            case 0xFF61...0xFF9F: score -= 2
            case 0xE000...0xF8FF, 0xFFFD: score -= 5
            default: break
            }
        }
        return score
    }

    /// How many names do not read as text in `encoding`.
    public static func unreadableCount(_ entries: [ArchiveEntry], as encoding: ArchiveNameEncoding) -> Int {
        entries.filter { !decode($0, as: encoding).readable }.count
    }

    /// The parts of a path inside an archive, or nil when it is unsafe: a
    /// ".." component or a NUL. Backslashes separate parts, as Windows
    /// archivers write them; a leading "/" or "./" and empty or "." parts are
    /// dropped.
    public static func sanitizedPath(_ name: String) -> [String]? {
        var components: [String] = []
        for part in name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part.unicodeScalars.contains(where: { $0.value == 0 }) { return nil }
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(String(part))
        }
        return components
    }

    /// Files archivers and file managers add that are not part of the game.
    public static func isIgnorable(_ components: [String]) -> Bool {
        guard let last = components.last else { return true }
        if components.contains("__MACOSX") { return true }
        return [".DS_Store", "Thumbs.db", "desktop.ini"].contains(last) || last.hasPrefix("._")
    }
}

// MARK: - Layout

/// A folder in an archive that holds a game.
public struct ArchiveRootCandidate: Sendable, Equatable, Identifiable {
    /// The folder's path; empty for the whole archive.
    public var path: [String]
    public var engines: [EngineID]
    public var byteCount: Int64
    public var fileCount: Int

    public var id: String { path.joined(separator: "/") }

    public init(path: [String], engines: [EngineID], byteCount: Int64, fileCount: Int) {
        self.path = path
        self.engines = engines
        self.byteCount = byteCount
        self.fileCount = fileCount
    }
}

/// One name directly inside a folder of the archive, with what it holds.
public struct ArchiveChild: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var byteCount: Int64
    public var fileCount: Int
}

/// The files of an archive with their names read and cleaned.
public struct ArchiveLayout: Sendable {
    public struct Item: Sendable, Equatable {
        public var components: [String]
        public var entry: ArchiveEntry
    }

    /// Every entry with a safe path, links and ignorable files dropped.
    public let items: [Item]
    /// Every folder, including those only a file's path implies.
    public let directories: Set<[String]>

    /// - Parameter encoding: how ZIP names are read; `.automatic` detects it.
    public init(listing: ArchiveListing, encoding: ArchiveNameEncoding) {
        let resolved = encoding == .automatic ? ArchiveNames.detect(listing.entries) : encoding
        var items: [Item] = []
        var directories = Set<[String]>()
        for entry in listing.entries {
            guard let components = Self.components(of: entry, encoding: resolved) else { continue }
            items.append(Item(components: components, entry: entry))
            let folderDepth = entry.isDirectory ? components.count : components.count - 1
            if folderDepth > 0 {
                for depth in 1...folderDepth { directories.insert(Array(components.prefix(depth))) }
            }
        }
        self.items = items
        self.directories = directories
    }

    /// The clean path of an entry, or nil when it is not extracted: a link, an
    /// ignorable file, an empty or unsafe path.
    public static func components(of entry: ArchiveEntry, encoding: ArchiveNameEncoding) -> [String]? {
        guard !entry.isLink else { return nil }
        let name = ArchiveNames.decode(entry, as: encoding).name
        guard let components = ArchiveNames.sanitizedPath(name), !components.isEmpty,
              !ArchiveNames.isIgnorable(components) else { return nil }
        return components
    }

    /// Where an entry goes inside the game folder when `root` is the game's
    /// folder in the archive, or nil when it is skipped: not extracted, outside
    /// `root`, or `root` itself.
    public static func destination(of entry: ArchiveEntry, encoding: ArchiveNameEncoding, root: [String]) -> [String]? {
        guard let components = components(of: entry, encoding: encoding),
              components.count > root.count, components.starts(with: root) else { return nil }
        return Array(components.dropFirst(root.count))
    }

    private func isUnder(_ item: Item, _ root: [String]) -> Bool {
        item.components.count > root.count && item.components.starts(with: root)
    }

    /// Total size of the files inside `root`.
    public func bytes(under root: [String]) -> Int64 {
        items.reduce(0) { total, item in
            isUnder(item, root) && !item.entry.isDirectory ? total + max(item.entry.size, 0) : total
        }
    }

    /// Number of files inside `root`.
    public func files(under root: [String]) -> Int {
        items.filter { isUnder($0, root) && !$0.entry.isDirectory }.count
    }

    /// Where a game may start: the archive root and every folder up to three
    /// levels down in which an engine recognizes a game, shallowest first.
    /// A folder inside another candidate is left out. When nothing is
    /// recognized the single top folder (or else the whole archive) is the
    /// one candidate, with no engine.
    public func gameRootCandidates() -> [ArchiveRootCandidate] {
        let folders = directories.filter { $0.count <= 3 }.sorted(by: Self.isOrderedBefore)
        var roots: [[String]] = [[]]
        roots += folders.prefix(Self.probeLimit)
        var candidates: [ArchiveRootCandidate] = []
        for root in roots {
            // Each probe looks at the whole archive, so a folder an earlier
            // candidate holds is not worth one.
            if candidates.contains(where: { root.starts(with: $0.path) }) { continue }
            guard let engines = try? ArchiveProbe.detectEngines(layout: self, root: root), !engines.isEmpty else { continue }
            candidates.append(candidate(root, engines: engines))
        }
        if !candidates.isEmpty { return candidates }

        let topLevel = Set(items.map { $0.components[0] })
        let hasTopFile = items.contains { $0.components.count == 1 && !$0.entry.isDirectory }
        if topLevel.count == 1, !hasTopFile, let only = topLevel.first {
            return [candidate([only], engines: [])]
        }
        return [candidate([], engines: [])]
    }

    /// Folders probed at most, so a huge archive stays quick to read.
    private static let probeLimit = 300

    private func candidate(_ root: [String], engines: [EngineID]) -> ArchiveRootCandidate {
        ArchiveRootCandidate(path: root, engines: engines, byteCount: bytes(under: root), fileCount: files(under: root))
    }

    private static func isOrderedBefore(_ lhs: [String], _ rhs: [String]) -> Bool {
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return lhs.joined(separator: "/").localizedStandardCompare(rhs.joined(separator: "/")) == .orderedAscending
    }

    /// The names directly inside `root`, folders first and then by name.
    public func children(of root: [String]) -> [ArchiveChild] {
        var found: [String: ArchiveChild] = [:]
        for item in items where isUnder(item, root) {
            let name = item.components[root.count]
            let isDeeper = item.components.count > root.count + 1
            var child = found[name] ?? ArchiveChild(name: name, isDirectory: false, byteCount: 0, fileCount: 0)
            if isDeeper || item.entry.isDirectory { child.isDirectory = true }
            if !item.entry.isDirectory {
                child.byteCount += max(item.entry.size, 0)
                child.fileCount += 1
            }
            found[name] = child
        }
        return found.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The top-level names that are not inside `root`; these are left out of
    /// the import.
    public func topLevelOutside(_ root: [String]) -> [ArchiveChild] {
        guard !root.isEmpty else { return [] }
        let outside = ArchiveLayout(items: items.filter { !isUnder($0, root) && !root.starts(with: $0.components) })
        return outside.children(of: [])
    }

    private init(items: [Item]) {
        self.items = items
        self.directories = []
    }

    /// A folder name for the game: the last folder of `root`, or for the
    /// whole archive the archive's file name without its extension and
    /// without `.part1`, `.7z.001` or `.z01` endings. It always passes the
    /// library's folder name rules.
    public func suggestedFolderName(root: [String], archiveURL: URL) -> String {
        let base = root.last ?? Self.baseName(of: archiveURL.lastPathComponent)
        return Self.validFolderName(base)
    }

    static func baseName(of fileName: String) -> String {
        var name = fileName
        for pattern in [#"\.part\d+\.rar$"#, #"\.(zip|rar|7z)\.\d{3}$"#, #"\.(zip|rar|7z|r\d\d|z\d\d)$"#] {
            let stripped = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            if stripped != name {
                name = stripped
                break
            }
        }
        return name
    }

    /// `name` with the characters a game folder can't have replaced, so
    /// `LibraryRepository` accepts it.
    static func validFolderName(_ name: String) -> String {
        var result = name.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Game" : result
    }
}

// MARK: - Engine probe

/// Finds the engine of a game in an archive from its file list.
public enum ArchiveProbe {
    /// Files written to a probe at most.
    static let fileLimit = 20_000
    /// How many levels below the game's folder are looked at.
    static let depthLimit = 4

    /// The engines `GameScanner` finds in the files under `root`.
    ///
    /// A skeleton of the folder is built in the temporary directory: the same
    /// names, empty files, except that `.xp3` files carry the XP3 signature
    /// and `data.pac` the PAC one, since detection reads those. The skeleton
    /// is removed afterwards. A KiriKiri game packed only into an `.exe` can't
    /// be seen this way and is found after extraction instead.
    public static func detectEngines(layout: ArchiveLayout, root: [String]) throws -> [EngineID] {
        let fm = FileManager.default
        let skeleton = fm.temporaryDirectory.appendingPathComponent("mikage-probe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: skeleton, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: skeleton) }

        var written = 0
        for item in layout.items {
            guard item.components.count > root.count, item.components.starts(with: root) else { continue }
            let relative = Array(item.components.dropFirst(root.count))
            guard relative.count <= depthLimit else { continue }
            let target = relative.reduce(skeleton) { $0.appendingPathComponent($1) }
            if item.entry.isDirectory {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let name = relative[relative.count - 1].lowercased()
            let contents: Data
            if name.hasSuffix(".xp3") {
                contents = GameScanner.xp3Signature
            } else if name == "data.pac" {
                contents = Data("PAC ".utf8)
            } else {
                contents = Data()
            }
            fm.createFile(atPath: target.path, contents: contents)
            written += 1
            if written >= fileLimit { break }
        }
        return try GameScanner.detectEngines(in: skeleton)
    }
}

// MARK: - Archive files and their parts

/// What a file name says about an archive: its format, and where it sits in
/// a split set (`x.part2.rar`, `x.7z.002`, `x.r01`, `x.z01`).
struct ArchiveFileName {
    let format: ArchiveFormat
    /// The name without the format or part ending, as written.
    let stem: String
    /// Names of one set share a stem and a variant.
    let variant: String
    /// Position within the set, for sorting.
    let order: Int
    /// The part number as written, for a split part; nil for the main file.
    let number: Int?
    /// Digits the number is written with.
    let width: Int
    /// Whether this is the file a person picks (the first part or the only file).
    let isFirst: Bool
    /// The extension of numbered parts (`7z`, `zip`, `rar`).
    let ext: String

    init?(_ fileName: String) {
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let found = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName))
            else { return nil }
            return (1..<found.numberOfRanges).map { index in
                Range(found.range(at: index), in: fileName).map { String(fileName[$0]) } ?? ""
            }
        }
        func format(_ ext: String) -> ArchiveFormat {
            switch ext.lowercased() {
            case "zip": return .zip
            case "rar": return .rar
            default: return .sevenZip
            }
        }
        if let g = match(#"^(.+)\.part(\d+)\.rar$"#), let n = Int(g[1]) {
            self.init(format: .rar, stem: g[0], variant: "part", order: n, number: n, width: g[1].count, isFirst: n == 1, ext: "rar")
        } else if let g = match(#"^(.+)\.(7z|zip|rar)\.(\d{3})$"#), let n = Int(g[2]) {
            self.init(format: format(g[1]), stem: g[0], variant: "num-\(g[1].lowercased())", order: n, number: n, width: 3, isFirst: n == 1, ext: g[1].lowercased())
        } else if let g = match(#"^(.+)\.r(\d\d)$"#), let n = Int(g[1]) {
            self.init(format: .rar, stem: g[0], variant: "old", order: n + 1, number: n, width: 2, isFirst: false, ext: "rar")
        } else if let g = match(#"^(.+)\.z(\d\d)$"#), let n = Int(g[1]) {
            self.init(format: .zip, stem: g[0], variant: "zip", order: n, number: n, width: 2, isFirst: false, ext: "zip")
        } else if let g = match(#"^(.+)\.rar$"#) {
            self.init(format: .rar, stem: g[0], variant: "old", order: 0, number: nil, width: 0, isFirst: true, ext: "rar")
        } else if let g = match(#"^(.+)\.zip$"#) {
            self.init(format: .zip, stem: g[0], variant: "zip", order: Int.max, number: nil, width: 0, isFirst: true, ext: "zip")
        } else if let g = match(#"^(.+)\.7z$"#) {
            self.init(format: .sevenZip, stem: g[0], variant: "7z", order: 0, number: nil, width: 0, isFirst: true, ext: "7z")
        } else {
            return nil
        }
    }

    private init(format: ArchiveFormat, stem: String, variant: String, order: Int, number: Int?, width: Int, isFirst: Bool, ext: String) {
        self.format = format
        self.stem = stem
        self.variant = variant
        self.order = order
        self.number = number
        self.width = width
        self.isFirst = isFirst
        self.ext = ext
    }

    /// Files with the same key belong to one archive.
    func setKey(folder: String) -> String {
        "\(folder)|\(stem.lowercased())|\(variant)"
    }

    /// The file name of volume `n` of this set.
    func volumeName(_ n: Int) -> String {
        let digits = String(n)
        let padded = String(repeating: "0", count: max(width - digits.count, 0)) + digits
        switch variant {
        case "part": return "\(stem).part\(padded).rar"
        case "old": return "\(stem).r\(padded)"
        case "zip": return "\(stem).z\(padded)"
        default: return "\(stem).\(ext).\(padded)"
        }
    }
}

/// Grouping the files of split archives into sets.
public enum ArchiveParts {
    /// The files grouped by archive, each set in reading order: `.part1.rar`,
    /// `.part2.rar`; `.7z.001`, `.7z.002`; `.rar`, `.r00`, `.r01`; `.z01`,
    /// `.z02`, then `.zip` last. Files that are not archives are dropped.
    /// Sets keep the order in which their first file appears.
    public static func group(_ urls: [URL]) -> [[URL]] {
        var order: [String] = []
        var sets: [String: [(name: ArchiveFileName, url: URL)]] = [:]
        for url in urls {
            guard let name = ArchiveFileName(url.lastPathComponent) else { continue }
            let key = name.setKey(folder: url.deletingLastPathComponent().standardizedFileURL.path)
            if sets[key] == nil { order.append(key) }
            sets[key, default: []].append((name, url))
        }
        return order.map { key in
            (sets[key] ?? []).sorted { $0.name.order < $1.name.order }.map(\.url)
        }
    }

    /// The name of the first file a set lacks, or nil when it is complete:
    /// a gap in the part numbers, or the main file of a `.rNN` or `.zNN` set.
    public static func missingPart(in set: [URL]) -> String? {
        let names = set.compactMap { ArchiveFileName($0.lastPathComponent) }
        guard let sample = names.first else { return nil }
        let numbers = Set(names.compactMap(\.number))
        let hasMain = names.contains { $0.number == nil }
        switch sample.variant {
        case "part", "num-7z", "num-zip", "num-rar", "old", "zip":
            let lowest = sample.variant == "old" ? 0 : 1
            guard let highest = numbers.max(), highest >= lowest else { return nil }
            for n in lowest...highest where !numbers.contains(n) {
                return sample.volumeName(n)
            }
            if !hasMain && sample.variant == "old" { return "\(sample.stem).rar" }
            if !hasMain && sample.variant == "zip" { return "\(sample.stem).zip" }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Archives in Documents

extension LibraryRepository {
    /// An archive the player chose not to import, kept so it isn't offered
    /// again. The size tells a replaced file with the same name apart.
    struct IgnoredArchive: Codable, Equatable {
        var name: String
        var size: Int64
    }

    var ignoredArchivesURL: URL { metadataRoot.appendingPathComponent("ignored-archives.json") }

    private func ignoredArchives() -> [IgnoredArchive] {
        guard let data = try? Data(contentsOf: ignoredArchivesURL) else { return [] }
        return (try? JSONDecoder().decode([IgnoredArchive].self, from: data)) ?? []
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// The ZIP, RAR and 7z archives directly in Documents, first parts only,
    /// without the ones the player ignored.
    public func archivesInDocuments() throws -> [URL] {
        let ignored = ignoredArchives()
        let children = try FileManager.default.contentsOfDirectory(
            at: gamesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return children.filter { url in
            guard ArchiveFileName(url.lastPathComponent)?.isFirst == true,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            let name = url.lastPathComponent
            let size = fileSize(url)
            return !ignored.contains { $0.name == name && $0.size == size }
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Stops `archivesInDocuments` from listing this archive again.
    public func ignoreArchive(_ url: URL) throws {
        var ignored = ignoredArchives()
        let entry = IgnoredArchive(name: url.lastPathComponent, size: fileSize(url))
        guard !ignored.contains(entry) else { return }
        ignored.append(entry)
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(ignored).write(to: ignoredArchivesURL, options: .atomic)
    }

    /// Every file of the archive `first` belongs to, in reading order, found
    /// in the same folder. `first` itself when it has no other parts.
    public func archiveParts(for first: URL) -> [URL] {
        let folder = first.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { folder.appendingPathComponent($0) }
        let wanted = first.lastPathComponent
        let sets = ArchiveParts.group(siblings)
        return sets.first { set in
            set.contains { $0.lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame }
        } ?? [first]
    }

    /// The combined size of the files of an archive.
    public func archiveByteCount(_ parts: [URL]) -> Int64 {
        parts.reduce(0) { $0 + fileSize($1) }
    }
}
