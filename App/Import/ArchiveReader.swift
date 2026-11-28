import Foundation
import LibArchive
import VNCore

/// Why an archive could not be read or extracted.
enum ArchiveReaderError: LocalizedError {
    case needsPassword
    case wrongPassword
    /// A password-protected RAR or 7z, which libarchive can't open.
    case encryptedUnsupported
    case missingPart(String)
    case damaged(entry: String?)
    case unsupported
    case cancelled
    case notEnoughSpace(needed: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .needsPassword:
            return String(localized: "This archive is protected by a password.")
        case .wrongPassword:
            return String(localized: "That password isn’t right. Try again.")
        case .encryptedUnsupported:
            return String(localized: "Password-protected RAR and 7z archives can’t be opened yet. Extract it on a computer and copy the folder in.")
        case .missingPart(let name):
            return String(localized: "“\(name)” wasn’t found next to the other parts. Put every part (.part1.rar, .z01, .7z.001 …) in the same folder, then pick the first one.")
        case .damaged(let entry):
            if let entry {
                return String(localized: "The archive is damaged at \(entry). Nothing was added. Download it again and retry.")
            }
            return String(localized: "The archive is damaged. Nothing was added. Download it again and retry.")
        case .unsupported:
            return String(localized: "This file can’t be read as a ZIP, RAR or 7z archive.")
        case .cancelled:
            return String(localized: "Extracting was stopped.")
        case .notEnoughSpace(let needed, let free):
            return String(localized: "Extracting needs \(AppModel.size(needed)), and \(AppModel.size(free)) is free. Remove games or saves in Settings › Storage, then try again.")
        }
    }
}

/// Reads and extracts ZIP, RAR and 7z archives with libarchive. Both calls
/// are synchronous and block: run them off the main actor.
struct ArchiveReader: Sendable {
    /// The files of the archive in reading order; a split archive passes all
    /// of its volumes.
    let parts: [URL]
    var password: String?

    private static let reportInterval: Int64 = 1_048_576

    // MARK: Listing

    /// The archive's file list. Nothing is written.
    func list() throws -> ArchiveListing {
        let locale = ThreadLocale()
        defer { locale.restore() }
        let archive = try OpenArchive(parts: parts, password: password)

        var entries: [ArchiveEntry] = []
        var format: ArchiveFormat?
        var verifiedPassword = false
        while true {
            var raw: OpaquePointer?
            let status = archive_read_next_header(archive.handle, &raw)
            if status == ARCHIVE_EOF { break }
            // A warning still returns the header.
            if status < ARCHIVE_WARN { throw archive.error(entry: entries.last.map(Self.displayName)) }
            guard let header = raw else { break }
            if format == nil { format = Self.format(of: archive.handle) }
            guard let isZip = format.map({ $0 == .zip }), let entry = Self.describe(header, isZip: isZip) else { continue }
            entries.append(entry)

            // A wrong password only shows when data is read, so read the
            // start of the first protected file to find out now.
            if password != nil, entry.isEncrypted, !entry.isDirectory, entry.size > 0, !verifiedPassword {
                verifiedPassword = true
                var block: UnsafeRawPointer?
                var length = 0
                var offset: Int64 = 0
                if archive_read_data_block(archive.handle, &block, &length, &offset) < ARCHIVE_WARN {
                    throw archive.error(entry: Self.displayName(entry))
                }
            }
        }
        guard let format else { throw ArchiveReaderError.unsupported }
        if format != .zip, entries.contains(where: \.isEncrypted) { throw ArchiveReaderError.encryptedUnsupported }
        return ArchiveListing(format: format, entries: entries, archiveSize: Self.size(of: parts))
    }

    private static func size(of parts: [URL]) -> Int64 {
        parts.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private static func displayName(_ entry: ArchiveEntry) -> String {
        ArchiveNames.decode(entry, as: .utf8).name
    }

    private static func format(of handle: OpaquePointer) -> ArchiveFormat? {
        switch archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_ZIP: return .zip
        case ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_RAR_V5: return .rar
        case ARCHIVE_FORMAT_7ZIP: return .sevenZip
        default: return nil
        }
    }

    /// The entry's names and flags, or nil when it has no name at all.
    private static func describe(_ header: OpaquePointer, isZip: Bool) -> ArchiveEntry? {
        let local = bytes(archive_entry_pathname(header))
        let utf8 = bytes(archive_entry_pathname_utf8(header))
        guard let rawName = local ?? utf8 else { return nil }
        let unicode = isZip ? nil : utf8.flatMap { String(data: Data($0), encoding: .utf8) }
        let size: Int64 = archive_entry_size_is_set(header) != 0 ? max(archive_entry_size(header), 0) : 0
        // The file type bits of the mode: 0o040000 is a folder.
        let isDirectory = UInt32(archive_entry_filetype(header)) & 0o170000 == 0o040000
        let isLink = archive_entry_symlink(header) != nil || archive_entry_hardlink(header) != nil
        return ArchiveEntry(
            rawName: rawName,
            unicodeName: unicode,
            size: isDirectory ? 0 : size,
            isDirectory: isDirectory,
            isEncrypted: archive_entry_is_encrypted(header) != 0,
            isLink: isLink
        )
    }

    private static func bytes(_ pointer: UnsafePointer<CChar>?) -> [UInt8]? {
        guard let pointer else { return nil }
        let length = strlen(pointer)
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            Array(UnsafeBufferPointer(start: $0, count: length))
        }
    }

    // MARK: Extracting

    /// Writes the files under `root` into `staging`, without the `root`
    /// folders. `encoding` must be resolved, not `.automatic`: it is the one
    /// the file names were checked with. `progress` gets the bytes written and
    /// the file being written about every megabyte; returning false stops the
    /// extraction with `.cancelled`.
    func extract(
        root: [String],
        encoding: ArchiveNameEncoding,
        into staging: URL,
        progress: @Sendable (_ doneBytes: Int64, _ currentName: String) -> Bool
    ) throws {
        let locale = ThreadLocale()
        defer { locale.restore() }
        let archive = try OpenArchive(parts: parts, password: password)
        let fm = FileManager.default
        var done: Int64 = 0
        var reported: Int64 = 0
        var format: ArchiveFormat?

        while true {
            var raw: OpaquePointer?
            let status = archive_read_next_header(archive.handle, &raw)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw archive.error(entry: nil) }
            guard let header = raw else { break }
            if format == nil { format = Self.format(of: archive.handle) }
            guard let entry = Self.describe(header, isZip: format == .zip),
                  let relative = ArchiveLayout.destination(of: entry, encoding: encoding, root: root) else {
                archive_read_data_skip(archive.handle)
                continue
            }
            let name = relative.joined(separator: "/")
            if entry.isDirectory {
                try fm.createDirectory(at: try GameScanner.containedURL(name, in: staging), withIntermediateDirectories: true)
                continue
            }
            if !progress(done, relative[relative.count - 1]) { throw ArchiveReaderError.cancelled }

            let target = try GameScanner.containedURL(name, in: staging)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(entry: entry, header: header, to: target, name: name, archive: archive, staging: staging) { written in
                done += written
                if done - reported >= Self.reportInterval {
                    reported = done
                    return progress(done, relative[relative.count - 1])
                }
                return true
            }
        }
    }

    /// Copies the current entry's data to `target`.
    private func write(
        entry: ArchiveEntry,
        header: OpaquePointer,
        to target: URL,
        name: String,
        archive: OpenArchive,
        staging: URL,
        advance: (Int64) -> Bool
    ) throws {
        guard let file = fopen(target.path, "wb") else {
            throw writeFailure(entry: entry, staging: staging, name: name)
        }
        var closed = false
        defer { if !closed { fclose(file) } }

        var position: Int64 = 0
        while true {
            var block: UnsafeRawPointer?
            var length = 0
            var offset: Int64 = 0
            let status = archive_read_data_block(archive.handle, &block, &length, &offset)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw archive.error(entry: name) }
            guard let block, length > 0 else { continue }
            // Sparse files skip over holes.
            if offset != position { fseeko(file, off_t(offset), SEEK_SET) }
            guard fwrite(block, 1, length, file) == length else {
                throw writeFailure(entry: entry, staging: staging, name: name)
            }
            position = offset + Int64(length)
            if !advance(Int64(length)) { throw ArchiveReaderError.cancelled }
        }
        closed = true
        fclose(file)
        if archive_entry_mtime_is_set(header) != 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(header)))
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        }
    }

    private func writeFailure(entry: ArchiveEntry, staging: URL, name: String) -> ArchiveReaderError {
        guard errno == ENOSPC else { return .damaged(entry: name) }
        return .notEnoughSpace(needed: entry.size, free: Self.freeSpace(at: staging) ?? 0)
    }

    // MARK: Space

    /// Bytes the system lets the app use on the volume of `url`.
    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - libarchive handle

/// An open libarchive reader, freed with it.
private final class OpenArchive {
    let handle: OpaquePointer
    private let parts: [URL]
    private let hasPassword: Bool

    init(parts: [URL], password: String?) throws {
        guard let created = archive_read_new() else { throw ArchiveReaderError.unsupported }
        handle = created
        self.parts = parts
        hasPassword = password?.isEmpty == false

        archive_read_support_filter_all(handle)
        archive_read_support_format_zip(handle)
        archive_read_support_format_rar(handle)
        archive_read_support_format_rar5(handle)
        archive_read_support_format_7zip(handle)
        if let password, !password.isEmpty { archive_read_add_passphrase(handle, password) }

        var paths: [UnsafePointer<CChar>?] = []
        defer { for path in paths { free(UnsafeMutablePointer(mutating: path)) } }
        for part in parts {
            guard let copy = part.withUnsafeFileSystemRepresentation({ $0.flatMap { strdup($0) } }) else {
                throw ArchiveReaderError.unsupported
            }
            paths.append(UnsafePointer(copy))
        }
        paths.append(nil)
        let status = paths.withUnsafeMutableBufferPointer {
            archive_read_open_filenames(handle, $0.baseAddress, 64 * 1024)
        }
        if status < ARCHIVE_WARN { throw error(entry: nil) }
    }

    deinit { archive_read_free(handle) }

    /// The error for the failure just reported. The message is only read
    /// after a failure: after a success it may be left over from before.
    func error(entry: String?) -> ArchiveReaderError {
        let pointer: UnsafePointer<CChar>? = archive_error_string(handle)
        let message = pointer.map { String(cString: $0).lowercased() } ?? ""

        if message.contains("incorrect passphrase") || message.contains("incorrect password") {
            return .wrongPassword
        }
        if message.contains("passphrase") || message.contains("password") {
            return hasPassword ? .wrongPassword : .needsPassword
        }
        if message.contains("currently not supported") || message.contains("encryption support unavailable")
            || message.contains("encryption is not supported") {
            return .encryptedUnsupported
        }
        // Volumes that are missing or out of order surface as data errors.
        let volumeErrors = ["bad rar file data", "truncated rar5", "subsequent volume", "too small block", "truncated rar"]
        if volumeErrors.contains(where: message.contains) {
            return looksSplit ? .missingPart(parts[0].lastPathComponent) : .damaged(entry: entry)
        }
        if message.contains("unrecognized archive format") || message.contains("unsupported") {
            return .unsupported
        }
        return .damaged(entry: entry)
    }

    /// Whether the archive is, by its files or name, one volume of several.
    private var looksSplit: Bool {
        if parts.count > 1 { return true }
        let name = parts[0].lastPathComponent.lowercased()
        return name.contains(".part")
            || name.range(of: #"\.(r\d\d|z\d\d|\d{3})$"#, options: .regularExpression) != nil
    }
}

// MARK: - Thread locale

/// A UTF-8 character set for the calling thread while libarchive runs: in the
/// plain C locale it returns no names for Unicode file names. It leaves the
/// process-wide locale alone and must be created on the thread that makes the
/// libarchive calls.
private struct ThreadLocale {
    private let installed: locale_t?
    private let previous: locale_t?

    init() {
        let created = newlocale(LC_CTYPE_MASK, "UTF-8", nil) ?? newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)
        installed = created
        previous = created.map { uselocale($0) }
    }

    func restore() {
        guard let installed, let previous else { return }
        uselocale(previous)
        freelocale(installed)
    }
}
