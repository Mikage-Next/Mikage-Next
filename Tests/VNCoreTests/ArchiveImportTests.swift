import XCTest
@testable import VNCore

final class ArchiveImportTests: XCTestCase {
    private var sandbox: URL!
    private var documents: URL!
    private var repository: LibraryRepository!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        documents = sandbox.appendingPathComponent("Documents", isDirectory: true)
        let metadata = sandbox.appendingPathComponent("Application Support/Mikage", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        repository = LibraryRepository(documentsRoot: documents, metadataRoot: metadata)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// A ZIP-style entry whose name is stored as `encoding` bytes.
    private func zipEntry(_ name: String, as encoding: String.Encoding = .utf8, directory: Bool = false) throws -> ArchiveEntry {
        let data = try XCTUnwrap(name.data(using: encoding))
        return ArchiveEntry(rawName: [UInt8](data), size: directory ? 0 : 10, isDirectory: directory)
    }

    /// A RAR or 7z entry, which carries its Unicode name.
    private func unicodeEntry(_ name: String, directory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(rawName: Array(name.utf8), unicodeName: name, size: directory ? 0 : 10, isDirectory: directory)
    }

    private func listing(_ entries: [ArchiveEntry], format: ArchiveFormat = .zip) -> ArchiveListing {
        ArchiveListing(format: format, entries: entries, archiveSize: 100)
    }

    // MARK: Names

    func testDetectsUTF8Names() throws {
        let entries = [
            try zipEntry("サクラノ詩/はじめに.txt"),
            try zipEntry("readme.txt")
        ]
        XCTAssertEqual(ArchiveNames.detect(entries), .utf8)
        XCTAssertEqual(ArchiveNames.unreadableCount(entries, as: .utf8), 0)
    }

    func testDetectsShiftJISNames() throws {
        let entries = [try zipEntry("サクラノ詩/はじめに.txt", as: .shiftJIS)]
        XCTAssertEqual(ArchiveNames.detect(entries), .shiftJIS)
        XCTAssertEqual(ArchiveNames.decode(entries[0], as: .shiftJIS).name, "サクラノ詩/はじめに.txt")
    }

    func testDetectsGBKNames() throws {
        let gbk = String.Encoding(rawValue: 0x8000_0632)
        let entries = [try zipEntry("樱之诗/说明.txt", as: gbk)]
        XCTAssertEqual(ArchiveNames.detect(entries), .gbk)
        XCTAssertEqual(ArchiveNames.decode(entries[0], as: .gbk).name, "樱之诗/说明.txt")
    }

    func testPlainASCIINamesAreUTF8() throws {
        let entries = [try zipEntry("data/bgm01.ogg"), try zipEntry("Game.exe")]
        XCTAssertEqual(ArchiveNames.detect(entries), .utf8)
        // ASCII reads the same in every encoding.
        XCTAssertEqual(ArchiveNames.unreadableCount(entries, as: .shiftJIS), 0)
    }

    func testUnicodeNamesIgnoreTheEncoding() {
        let entry = unicodeEntry("サクラノ詩/system.arc")
        let decoded = ArchiveNames.decode(entry, as: .gbk)
        XCTAssertEqual(decoded.name, "サクラノ詩/system.arc")
        XCTAssertTrue(decoded.readable)
        XCTAssertEqual(ArchiveNames.detect([entry]), .utf8)
    }

    func testWrongEncodingIsUnreadable() throws {
        // Shift-JIS bytes that are not valid UTF-8.
        let entry = try zipEntry("はじめに.txt", as: .shiftJIS)
        let decoded = ArchiveNames.decode(entry, as: .utf8)
        XCTAssertFalse(decoded.readable)
        XCTAssertTrue(decoded.name.contains("\u{FFFD}"))
        XCTAssertEqual(ArchiveNames.unreadableCount([entry], as: .utf8), 1)
    }

    func testSanitizedPath() {
        XCTAssertEqual(ArchiveNames.sanitizedPath("a/b/c.txt"), ["a", "b", "c.txt"])
        XCTAssertEqual(ArchiveNames.sanitizedPath("a\\b\\c.txt"), ["a", "b", "c.txt"])
        XCTAssertEqual(ArchiveNames.sanitizedPath("/a/./b//c"), ["a", "b", "c"])
        XCTAssertEqual(ArchiveNames.sanitizedPath("./a"), ["a"])
        XCTAssertNil(ArchiveNames.sanitizedPath("a/../../b"))
        XCTAssertNil(ArchiveNames.sanitizedPath("..\\b"))
        XCTAssertNil(ArchiveNames.sanitizedPath("a/b\u{0}c"))
        XCTAssertEqual(ArchiveNames.sanitizedPath("/"), [])
    }

    func testIgnorableFiles() {
        XCTAssertTrue(ArchiveNames.isIgnorable(["__MACOSX", "Game", "x.txt"]))
        XCTAssertTrue(ArchiveNames.isIgnorable(["Game", "._x"]))
        XCTAssertTrue(ArchiveNames.isIgnorable([".DS_Store"]))
        XCTAssertTrue(ArchiveNames.isIgnorable(["Game", "Thumbs.db"]))
        XCTAssertTrue(ArchiveNames.isIgnorable(["Game", "desktop.ini"]))
        XCTAssertFalse(ArchiveNames.isIgnorable(["Game", "data.xp3"]))
    }

    // MARK: Game folders

    func testFindsTheFolderHoldingTheGame() throws {
        let layout = ArchiveLayout(
            listing: listing([
                unicodeEntry("サクラノ詩/system.arc"),
                unicodeEntry("サクラノ詩/BGI.exe"),
                unicodeEntry("readme.txt")
            ], format: .rar),
            encoding: .automatic
        )
        let candidates = layout.gameRootCandidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].path, ["サクラノ詩"])
        XCTAssertEqual(candidates[0].engines, [.bgi])
        XCTAssertEqual(candidates[0].fileCount, 2)
        XCTAssertEqual(candidates[0].byteCount, 20)
        XCTAssertEqual(layout.topLevelOutside(["サクラノ詩"]).map(\.name), ["readme.txt"])
    }

    func testFindsANestedKiriKiriFolder() throws {
        let layout = ArchiveLayout(
            listing: listing([try zipEntry("Game/Game/data.xp3"), try zipEntry("Game/Game/data/", directory: true)]),
            encoding: .automatic
        )
        let candidates = layout.gameRootCandidates()
        XCTAssertEqual(candidates.map(\.path), [["Game", "Game"]])
        XCTAssertEqual(candidates[0].engines, [.kirikiri])
    }

    func testGameAtTheArchiveRoot() throws {
        let layout = ArchiveLayout(
            listing: listing([try zipEntry("Scene.pck"), try zipEntry("Gameexe.dat"), try zipEntry("bgm/a.ogg")]),
            encoding: .automatic
        )
        let candidates = layout.gameRootCandidates()
        XCTAssertEqual(candidates.map(\.path), [[]])
        XCTAssertEqual(candidates[0].engines, [.siglus])
    }

    func testTheShallowerFolderWins() throws {
        let layout = ArchiveLayout(
            listing: listing([try zipEntry("Scene.pck"), try zipEntry("old/Scene.pck")]),
            encoding: .automatic
        )
        XCTAssertEqual(layout.gameRootCandidates().map(\.path), [[]])
    }

    func testUnrecognizedArchiveUsesItsOnlyFolder() throws {
        let layout = ArchiveLayout(
            listing: listing([try zipEntry("Mystery/a.bin"), try zipEntry("Mystery/sub/b.bin")]),
            encoding: .automatic
        )
        let candidates = layout.gameRootCandidates()
        XCTAssertEqual(candidates.map(\.path), [["Mystery"]])
        XCTAssertEqual(candidates[0].engines, [])
    }

    func testUnrecognizedArchiveWithFilesAtTheRootUsesTheWholeArchive() throws {
        let layout = ArchiveLayout(
            listing: listing([try zipEntry("Mystery/a.bin"), try zipEntry("setup.bin")]),
            encoding: .automatic
        )
        let candidates = layout.gameRootCandidates()
        XCTAssertEqual(candidates.map(\.path), [[]])
        XCTAssertEqual(candidates[0].engines, [])
    }

    func testFindsAGameManyFoldersDown() throws {
        let layout = ArchiveLayout(
            listing: listing([
                unicodeEntry("Release/v1.02/PC/JP/Game/Scene.pck"),
                unicodeEntry("Release/v1.02/PC/JP/Game/Gameexe.dat"),
                unicodeEntry("Release/readme.txt")
            ], format: .sevenZip),
            encoding: .automatic
        )
        XCTAssertEqual(layout.gameRootCandidates().map(\.path), [["Release", "v1.02", "PC", "JP", "Game"]])
    }

    func testUnrecognizedArchiveStepsIntoWrappingFolders() throws {
        let layout = ArchiveLayout(
            listing: listing([
                try zipEntry("Game v1.0/Game/a.bin"),
                try zipEntry("Game v1.0/Game/sub/b.bin"),
                try zipEntry("Game v1.0/readme.txt"),
                try zipEntry("info.url")
            ]),
            encoding: .automatic
        )
        XCTAssertEqual(layout.gameRootCandidates().map(\.path), [["Game v1.0", "Game"]])
    }

    func testArchiveHoldingOnlyArchives() throws {
        let wrapper = ArchiveLayout(
            listing: listing([
                try zipEntry("Game/game.part1.rar"),
                try zipEntry("Game/game.part2.rar"),
                try zipEntry("Game/", directory: true),
                try zipEntry("readme.txt")
            ]),
            encoding: .automatic
        )
        XCTAssertEqual(wrapper.wrappedArchives(), [["Game", "game.part1.rar"], ["Game", "game.part2.rar"]])

        // A game that ships a patch archive is not a wrapper.
        let game = ArchiveLayout(
            listing: listing([try zipEntry("Game/patch.zip"), try zipEntry("Game/Game.exe")]),
            encoding: .automatic
        )
        XCTAssertEqual(game.wrappedArchives(), [])
    }

    func testIgnorableFilesAndLinksAreNotPartOfTheLayout() throws {
        var link = unicodeEntry("Game/link")
        link.isLink = true
        let layout = ArchiveLayout(
            listing: listing([
                unicodeEntry("__MACOSX/Game/._data.xp3"),
                unicodeEntry("Game/.DS_Store"),
                unicodeEntry("../escape.txt"),
                link,
                unicodeEntry("Game/real.txt")
            ], format: .sevenZip),
            encoding: .automatic
        )
        XCTAssertEqual(layout.items.map(\.components), [["Game", "real.txt"]])
        XCTAssertEqual(ArchiveLayout.destination(of: unicodeEntry("Game/real.txt"), encoding: .utf8, root: ["Game"]), ["real.txt"])
        XCTAssertNil(ArchiveLayout.destination(of: unicodeEntry("Other/real.txt"), encoding: .utf8, root: ["Game"]))
    }

    func testSuggestedFolderNames() {
        let layout = ArchiveLayout(listing: listing([]), encoding: .utf8)
        func name(_ file: String, root: [String] = []) -> String {
            layout.suggestedFolderName(root: root, archiveURL: URL(fileURLWithPath: "/tmp/\(file)"))
        }
        XCTAssertEqual(name("foo.part1.rar"), "foo")
        XCTAssertEqual(name("bar.7z.001"), "bar")
        XCTAssertEqual(name("Baz.zip"), "Baz")
        XCTAssertEqual(name("Baz.ZIP"), "Baz")
        XCTAssertEqual(name("Baz.zip", root: ["Inner", "サクラノ詩"]), "サクラノ詩")
        // Whatever the archive is called, the library accepts the name.
        XCTAssertEqual(name(".hidden.zip"), "hidden")
        XCTAssertEqual(name("a:b.zip"), "a:b")
        XCTAssertEqual(layout.suggestedFolderName(root: ["a\\b"], archiveURL: URL(fileURLWithPath: "/tmp/x.zip")), "a_b")
    }

    // MARK: Archives in Documents

    private func touch(_ names: [String]) throws {
        for name in names {
            try Data("x".utf8).write(to: documents.appendingPathComponent(name))
        }
    }

    func testArchivePartsAreInReadingOrder() throws {
        try touch([
            "a.part1.rar", "a.part2.rar", "a.part10.rar", "other.part1.rar",
            "b.7z.001", "b.7z.002",
            "c.rar", "c.r00", "c.r01",
            "d.zip", "d.z01", "d.z02",
            "e.zip"
        ])
        func names(_ file: String) -> [String] {
            repository.archiveParts(for: documents.appendingPathComponent(file)).map(\.lastPathComponent)
        }
        XCTAssertEqual(names("a.part1.rar"), ["a.part1.rar", "a.part2.rar", "a.part10.rar"])
        XCTAssertEqual(names("a.part2.rar"), ["a.part1.rar", "a.part2.rar", "a.part10.rar"])
        XCTAssertEqual(names("b.7z.001"), ["b.7z.001", "b.7z.002"])
        XCTAssertEqual(names("c.rar"), ["c.rar", "c.r00", "c.r01"])
        XCTAssertEqual(names("d.zip"), ["d.z01", "d.z02", "d.zip"])
        XCTAssertEqual(names("e.zip"), ["e.zip"])
        XCTAssertEqual(names("missing.zip"), ["missing.zip"])
    }

    func testOnlyFirstPartsAreListedInDocuments() throws {
        try touch([
            "a.part1.rar", "a.part2.rar", "b.7z.001", "b.7z.002", "c.rar", "c.r00",
            "d.zip", "d.z01", "e.7z", "notes.txt", "f.001", "G.ZIP"
        ])
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Game.zip", isDirectory: true), withIntermediateDirectories: true)
        let names = try repository.archivesInDocuments().map(\.lastPathComponent)
        XCTAssertEqual(names, ["a.part1.rar", "b.7z.001", "c.rar", "d.zip", "e.7z", "G.ZIP"])
    }

    func testIgnoredArchivesAreNotListedAgain() throws {
        try touch(["a.zip", "b.zip"])
        try repository.ignoreArchive(documents.appendingPathComponent("a.zip"))
        XCTAssertEqual(try repository.archivesInDocuments().map(\.lastPathComponent), ["b.zip"])
        // A different file under the same name is offered again.
        try Data("longer".utf8).write(to: documents.appendingPathComponent("a.zip"))
        XCTAssertEqual(try repository.archivesInDocuments().map(\.lastPathComponent), ["a.zip", "b.zip"])
    }

    func testMissingPartsAreReported() {
        func urls(_ names: [String]) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }
        XCTAssertNil(ArchiveParts.missingPart(in: urls(["a.part1.rar", "a.part2.rar"])))
        XCTAssertEqual(ArchiveParts.missingPart(in: urls(["a.part2.rar"])), "a.part1.rar")
        XCTAssertEqual(ArchiveParts.missingPart(in: urls(["a.part01.rar", "a.part03.rar"])), "a.part02.rar")
        XCTAssertEqual(ArchiveParts.missingPart(in: urls(["b.7z.001", "b.7z.003"])), "b.7z.002")
        XCTAssertEqual(ArchiveParts.missingPart(in: urls(["c.r00"])), "c.rar")
        XCTAssertEqual(ArchiveParts.missingPart(in: urls(["d.z01"])), "d.zip")
        XCTAssertNil(ArchiveParts.missingPart(in: urls(["d.z01", "d.zip"])))
        XCTAssertNil(ArchiveParts.missingPart(in: urls(["e.7z"])))
    }

    func testNextPartIsNamedFromTheSet() {
        func urls(_ names: [String]) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }
        XCTAssertEqual(ArchiveParts.nextPart(after: urls(["a.part1.rar"])), "a.part2.rar")
        XCTAssertEqual(ArchiveParts.nextPart(after: urls(["a.part01.rar", "a.part02.rar"])), "a.part03.rar")
        XCTAssertEqual(ArchiveParts.nextPart(after: urls(["b.7z.001"])), "b.7z.002")
        XCTAssertEqual(ArchiveParts.nextPart(after: urls(["c.rar", "c.r00"])), "c.r01")
        XCTAssertEqual(ArchiveParts.nextPart(after: urls(["d.z01"])), "d.z02")
        XCTAssertNil(ArchiveParts.nextPart(after: urls(["d.z01", "d.zip"])))
        XCTAssertNil(ArchiveParts.nextPart(after: urls(["e.zip"])))
        XCTAssertNil(ArchiveParts.nextPart(after: urls(["f.rar"])))
    }

    func testArchiveSetsAreFoundInSubfolders() throws {
        let folder = sandbox.appendingPathComponent("unpacked", isDirectory: true)
        let inner = folder.appendingPathComponent("Game", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for name in ["game.part2.rar", "game.part1.rar", "readme.txt"] {
            try Data("x".utf8).write(to: inner.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: folder.appendingPathComponent("bonus.7z"))
        let sets = ArchiveParts.archiveSets(in: folder).map { $0.map(\.lastPathComponent) }
        XCTAssertEqual(sets, [["bonus.7z"], ["game.part1.rar", "game.part2.rar"]])
    }

    // MARK: Staging

    func testLiftsAGameFromInnerFolders() throws {
        let staging = try repository.makeStagingDirectory()
        let deep = staging.appendingPathComponent("Game v1.0/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data().write(to: deep.appendingPathComponent("Scene.pck"))
        try Data().write(to: deep.appendingPathComponent("Gameexe.dat"))
        try Data("x".utf8).write(to: staging.appendingPathComponent("Game v1.0/readme.txt"))

        XCTAssertEqual(try ArchiveStaging.liftGame(in: staging), [.siglus])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("Scene.pck").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("Game v1.0").path))
    }

    func testLiftLeavesAnUnknownFolderAlone() throws {
        let staging = try repository.makeStagingDirectory()
        try Data("x".utf8).write(to: staging.appendingPathComponent("a.bin"))
        XCTAssertEqual(try ArchiveStaging.liftGame(in: staging), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("a.bin").path))
    }


    func testAdoptingAStagedFolder() throws {
        let staging = try repository.makeStagingDirectory()
        XCTAssertTrue(staging.lastPathComponent.hasPrefix(".incoming-"))
        try Data("// sample".utf8).write(to: staging.appendingPathComponent("startup.tjs"))

        try repository.adoptStagedFolder(staging, folderName: "My Game", engine: .kirikiri)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let snapshot = try repository.scan()
        XCTAssertEqual(snapshot.active.map(\.folderName), ["My Game"])
        XCTAssertEqual(snapshot.active.first?.engine, .kirikiri)
        XCTAssertEqual(repository.uniqueFolderName("My Game"), "My Game 2")
        XCTAssertEqual(repository.uniqueFolderName("Other"), "Other")
    }

    func testAdoptingRejectsBadAndTakenNames() throws {
        let first = try repository.makeStagingDirectory()
        try Data("// sample".utf8).write(to: first.appendingPathComponent("startup.tjs"))
        XCTAssertThrowsError(try repository.adoptStagedFolder(first, folderName: ".hidden", engine: .kirikiri)) {
            XCTAssertEqual($0 as? LibraryError, .invalidFolderName)
        }
        try repository.adoptStagedFolder(first, folderName: "Taken", engine: .kirikiri)

        let second = try repository.makeStagingDirectory()
        XCTAssertThrowsError(try repository.adoptStagedFolder(second, folderName: "taken", engine: .kirikiri)) {
            XCTAssertEqual($0 as? LibraryError, .duplicateName("taken"))
        }
        repository.removeStagingDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }
}
