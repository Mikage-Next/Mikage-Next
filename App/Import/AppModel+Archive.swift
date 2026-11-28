import SwiftUI
import VNCore

// Importing games from ZIP, RAR and 7z archives: picking or finding them,
// reading the file list, the check sheet, extracting into a staging folder
// and adding the result to the library. One archive at a time; the others
// wait in a queue.

/// One archive waiting to be imported.
struct ArchiveJob {
    /// The files of the archive in reading order.
    var parts: [URL]
    /// Picked files whose security-scoped access is held while the job runs.
    var scoped: [URL]
    /// Whether the archive sits directly in Mikage's Documents folder.
    var inDocuments: Bool
    /// Skip the check sheet when everything is clear (archives found in
    /// Documents and imported from the new-games toast).
    var autoDefaults: Bool
    /// How many archives this one is packed in.
    var depth = 0
    /// The archive this one was packed in, for the check sheet.
    var container: String?
    /// Whether the check sheet offers Delete Archive After Import: for an
    /// archive in Mikage's folder, or one packed in such an archive (the
    /// outer archive is then the one deleted).
    var offersDelete = false
    /// The outer archive's password, tried first on an archive packed in it.
    var passwordHint: String?

    var first: URL { parts[0] }
}

/// How one archive's import ended.
enum ArchiveJobOutcome {
    /// Games were added; `deleteAfter` is the sheet's Delete Archive After
    /// Import.
    case imported(deleteAfter: Bool)
    case skipped

    var wasImported: Bool {
        if case .imported = self { return true }
        return false
    }
}

/// What the Import Archive sheet shows and the player can change.
struct ArchiveCheck: Identifiable {
    let id = UUID()
    var parts: [URL]
    var inDocuments: Bool
    var listing: ArchiveListing
    var password: String?
    /// The file name encoding chosen; `.automatic` follows `detectedEncoding`.
    var encoding: ArchiveNameEncoding = .automatic
    var detectedEncoding: ArchiveNameEncoding
    var layout: ArchiveLayout
    var candidates: [ArchiveRootCandidate]
    var candidateIndex = 0
    var folderName: String
    /// Whether the player typed the folder name, so it is left alone when the
    /// game folder or the names change.
    var folderNameEdited = false
    /// An engine the player chose by hand.
    var engineChoice: EngineID?
    var deleteAfter = true
    var freeBytes: Int64
    /// The archive this one was packed in.
    var container: String?
    var offersDelete = false

    var archiveURL: URL { parts[0] }
    var resolvedEncoding: ArchiveNameEncoding { encoding == .automatic ? detectedEncoding : encoding }
    var candidate: ArchiveRootCandidate { candidates[min(candidateIndex, candidates.count - 1)] }
    var neededBytes: Int64 { candidate.byteCount }
    var hasEnoughSpace: Bool { neededBytes <= freeBytes }

    /// The engine found in the file list, or the one the player chose.
    var engine: EngineID? {
        engineChoice ?? (candidate.engines.count == 1 ? candidate.engines[0] : nil)
    }

    var folderNameIsValid: Bool {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }

    /// Everything is clear without asking: one game folder, one engine, no
    /// password and room to extract.
    var isClearCut: Bool {
        candidates.count == 1 && candidate.engines.count == 1 && !listing.hasEncryptedEntries && hasEnoughSpace
    }
}

/// An extraction in progress, for the library card and the progress sheet.
struct ArchiveExtraction {
    var archiveName: String
    var engine: EngineID?
    var totalBytes: Int64
    var doneBytes: Int64 = 0
    var currentName = ""
    /// 1-based place of this archive in the queue, and the queue's length.
    var position = 1
    var queueLength = 1
    var startedAt = Date()
    /// Whether iOS shows the progress itself (iOS 26 continued processing).
    var systemProgress = false

    var fraction: Double {
        totalBytes > 0 ? min(max(Double(doneBytes) / Double(totalBytes), 0), 1) : 0
    }

    /// Time left at the speed so far; nil until there is a speed to go by.
    var remaining: TimeInterval? {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard doneBytes > 0, elapsed >= 2, doneBytes < totalBytes else { return nil }
        return elapsed * Double(totalBytes - doneBytes) / Double(doneBytes)
    }
}

struct ArchivePasswordRequest: Identifiable {
    let id = UUID()
    let archiveName: String
    let wrong: Bool
}

/// A problem shown in an alert, with an optional first button for the way on.
struct ArchiveAlert: Identifiable {
    enum FollowUp { case none, pickArchiveAgain, importFolder }
    let id = UUID()
    var title: String
    var message: String
    /// Title of the button that goes on; nil shows only OK.
    var primary: String?
    var cancel: String = String(localized: "Cancel")
    var followUp: FollowUp = .none
}

struct ArchiveEngineRequest: Identifiable {
    let id = UUID()
    let archiveName: String
    let detected: [EngineID]
}

/// Progress passed from the extracting thread, which can also be told to stop.
final class ExtractionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastPublish = Date.distantPast
    private let publish: @Sendable (Int64, String) -> Void

    init(publish: @escaping @Sendable (Int64, String) -> Void) {
        self.publish = publish
    }

    /// Returns false once the extraction should stop. Publishes at most ten
    /// times a second.
    func report(_ done: Int64, _ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        let now = Date()
        if now.timeIntervalSince(lastPublish) >= 0.1 {
            lastPublish = now
            publish(done, name)
        }
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Holds an iOS background task id so the expiration handler can end it.
final class BackgroundTaskBox {
    var id = UIBackgroundTaskIdentifier.invalid
}

/// Everything the import keeps between steps that the views don't show.
@MainActor
final class ArchiveImportState {
    var queue: [ArchiveJob] = []
    var current: ArchiveJob?
    var worker: Task<Void, Never>?
    /// Archives finished before the queue ran dry, for the "1 of 2" label.
    var finishedCount = 0
    /// Games added from archives since the queue started.
    var imported: [UUID] = []
    /// Games the toast found as folders, reviewed together with the archives.
    var reviewFirst: [UUID] = []

    var relay: ExtractionRelay?
    /// Stop Extracting was confirmed while this archive ran.
    var stopRequested = false
    /// The iOS 26 `ExtractionBackgroundTask`, if one is running.
    var background: AnyObject?
    var legacyTask: BackgroundTaskBox?

    var checkContinuation: CheckedContinuation<ArchiveCheck?, Never>?
    var passwordContinuation: CheckedContinuation<String?, Never>?
    var alertContinuation: CheckedContinuation<Bool, Never>?
    var engineContinuation: CheckedContinuation<EngineID?, Never>?

    /// Archives queued or running, so a rescan doesn't offer them again.
    var busyPaths: Set<String> {
        var paths = Set(queue.map { $0.first.standardizedFileURL.path })
        if let current { paths.insert(current.first.standardizedFileURL.path) }
        return paths
    }
}

extension AppModel {
    // MARK: Starting

    /// Imports the archives at `urls`. Parts of a split archive picked
    /// together form one archive. With `autoDefaults` an archive that is
    /// clear-cut is imported without the check sheet. `reviewAlso` are games
    /// the new-games toast found as folders: they are reviewed with the ones
    /// imported here.
    func beginArchiveImport(_ urls: [URL], fromFiles: Bool, autoDefaults: Bool = false, reviewAlso: [UUID] = []) {
        guard libraryReadable else { return }
        AppDiagnostics.shared.event("library", "archive.begin", ["count": String(urls.count), "fromFiles": String(fromFiles), "auto": String(autoDefaults)])

        var inside: [URL] = []
        var outside: [URL] = []
        for url in urls {
            if isInDocuments(url) { inside.append(url) } else { outside.append(url) }
        }
        var sets: [(parts: [URL], inDocuments: Bool)] = []
        var seen = Set<String>()
        for url in inside where ArchiveFormat(fileName: url.lastPathComponent) != nil {
            let parts = repository.archiveParts(for: url)
            if seen.insert(parts[0].standardizedFileURL.path).inserted { sets.append((parts, true)) }
        }
        for parts in ArchiveParts.group(outside) {
            sets.append((parts, false))
        }
        let busy = archiveState.busyPaths
        let jobs = sets.filter { !busy.contains($0.parts[0].standardizedFileURL.path) }.map {
            ArchiveJob(parts: $0.parts, scoped: fromFiles ? urls : [], inDocuments: $0.inDocuments, autoDefaults: autoDefaults, offersDelete: $0.inDocuments)
        }
        guard !jobs.isEmpty else {
            if sets.isEmpty { alert = String(localized: "Choose a ZIP, RAR or 7z archive.") }
            return
        }
        archiveState.queue.append(contentsOf: jobs)
        archiveState.reviewFirst += reviewAlso
        guard archiveState.worker == nil else { return }
        archiveState.worker = Task { await runArchiveQueue() }
    }

    /// A file another app or the Files app opened with Mikage.
    func handleOpenedURL(_ url: URL) {
        guard url.isFileURL, ArchiveFormat(fileName: url.lastPathComponent) != nil else { return }
        beginArchiveImport([url], fromFiles: true)
    }

    /// Whether this archive is queued or being imported.
    func isArchiveBusy(_ url: URL) -> Bool {
        archiveState.busyPaths.contains(url.standardizedFileURL.path)
    }

    private func isInDocuments(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return folder == repository.gamesRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func runArchiveQueue() async {
        let state = archiveState
        while !state.queue.isEmpty {
            let job = state.queue.removeFirst()
            state.current = job
            state.stopRequested = false
            await process(job)
            state.current = nil
            state.finishedCount += 1
        }
        state.finishedCount = 0
        state.worker = nil
        finishArchiveImports()
    }

    // MARK: One archive

    /// Archives packed in archives are opened this many levels deep.
    private static let maxDepth = 2

    @discardableResult
    private func process(_ job: ArchiveJob) async -> ArchiveJobOutcome {
        let scoped = job.scoped.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        let name = job.first.lastPathComponent

        if let missing = ArchiveParts.missingPart(in: job.parts) {
            AppDiagnostics.shared.event("library", "archive.missingPart", ["archive": name])
            await showArchiveAlert(failureAlert(ArchiveReaderError.missingPart(missing), archiveName: name))
            return .skipped
        }
        guard var check = await prepareCheck(job) else { return .skipped }
        if job.depth < Self.maxDepth,
           check.candidates.allSatisfy({ $0.engines.isEmpty }),
           !check.layout.wrappedArchives().isEmpty {
            return await unwrap(check, job: job)
        }
        if !(job.autoDefaults && check.isClearCut) {
            guard let confirmed = await askCheck(check) else {
                AppDiagnostics.shared.event("library", "archive.cancelled", ["archive": name])
                // An archive the player turned down is not offered again.
                if job.inDocuments { try? repository.ignoreArchive(job.first) }
                return .skipped
            }
            check = confirmed
        }
        return await extract(check)
    }

    /// An archive that only holds other archives (a ZIP with the parts of a
    /// RAR in it, say): it is extracted whole into a staging folder, each
    /// archive found there is imported as if it had been picked, and the
    /// staging folder is removed. The outer archive, when it is in Mikage's
    /// folder, is deleted only when every inner one was imported with Delete
    /// Archive After Import left on.
    private func unwrap(_ check: ArchiveCheck, job: ArchiveJob) async -> ArchiveJobOutcome {
        let name = job.first.lastPathComponent
        var whole = check
        whole.candidates = [ArchiveRootCandidate(
            path: [], engines: [],
            byteCount: check.layout.bytes(under: []), fileCount: check.layout.files(under: [])
        )]
        whole.candidateIndex = 0
        AppDiagnostics.shared.event("library", "archive.unwrap", ["archive": name, "depth": String(job.depth)])
        guard let result = await extractToStaging(whole) else { return .skipped }
        let (extracted, staging) = result
        endExtractionPresentation(success: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let sets = await Task.detached(priority: .userInitiated) {
            ArchiveParts.archiveSets(in: staging)
        }.value
        var outcomes: [ArchiveJobOutcome] = []
        for parts in sets {
            // Stop Extracting on one of them stops the rest too.
            if archiveState.stopRequested { break }
            let inner = ArchiveJob(
                parts: parts,
                scoped: [],
                inDocuments: false,
                autoDefaults: job.autoDefaults,
                depth: job.depth + 1,
                container: name,
                offersDelete: job.offersDelete,
                passwordHint: extracted.password
            )
            outcomes.append(await process(inner))
        }

        let allDeleted = !outcomes.isEmpty && outcomes.allSatisfy {
            if case .imported(deleteAfter: true) = $0 { return true }
            return false
        }
        if job.inDocuments {
            if allDeleted {
                for part in job.parts { try? FileManager.default.removeItem(at: part) }
            } else {
                try? repository.ignoreArchive(job.first)
            }
        }
        if allDeleted { return .imported(deleteAfter: true) }
        return outcomes.contains(where: \.wasImported) ? .imported(deleteAfter: false) : .skipped
    }

    /// Reads the file list, asking for a password when a ZIP needs one.
    private func prepareCheck(_ job: ArchiveJob) async -> ArchiveCheck? {
        let name = job.first.lastPathComponent
        let repository = self.repository
        var password = job.passwordHint
        var wrong = false
        while true {
            archiveReading = name
            let attempt = password
            let result: Result<ArchiveCheck, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try Self.makeCheck(job, password: attempt, repository: repository))
                } catch {
                    return .failure(error)
                }
            }.value
            archiveReading = nil
            switch result {
            case .success(let check):
                if check.listing.format == .zip, check.listing.hasEncryptedEntries, password == nil {
                    wrong = false
                } else {
                    AppDiagnostics.shared.event("library", "archive.listed", ["format": check.listing.format.rawValue, "entries": String(check.listing.entries.count), "engines": check.candidate.engines.map(\.rawValue).joined(separator: ",")])
                    return check
                }
            case .failure(let error):
                switch error as? ArchiveReaderError {
                case .wrongPassword?:
                    // The outer archive's password not fitting isn't the
                    // player's mistake.
                    wrong = attempt != nil && attempt != job.passwordHint
                case .needsPassword?:
                    wrong = false
                default:
                    AppDiagnostics.shared.event("library", "archive.listFailed", ["archive": name, "error": error.localizedDescription])
                    await showArchiveAlert(failureAlert(error, archiveName: name, listing: true))
                    return nil
                }
            }
            guard let entered = await askPassword(archiveName: name, wrong: wrong) else { return nil }
            password = entered
        }
    }

    /// Reads the archive and works out everything the check sheet shows. Runs
    /// off the main actor.
    nonisolated private static func makeCheck(_ job: ArchiveJob, password: String?, repository: LibraryRepository) throws -> ArchiveCheck {
        let reader = ArchiveReader(parts: job.parts, password: password)
        let listing = try reader.list()
        let detected = ArchiveNames.detect(listing.entries)
        let layout = ArchiveLayout(listing: listing, encoding: detected)
        let candidates = layout.gameRootCandidates()
        let first = candidates[0]
        var check = ArchiveCheck(
            parts: job.parts,
            inDocuments: job.inDocuments,
            listing: listing,
            password: password,
            detectedEncoding: detected,
            layout: layout,
            candidates: candidates,
            folderName: repository.uniqueFolderName(layout.suggestedFolderName(root: first.path, archiveURL: job.first)),
            freeBytes: ArchiveReader.freeSpace(at: repository.gamesRoot) ?? Int64.max
        )
        check.container = job.container
        check.offersDelete = job.offersDelete
        return check
    }

    // MARK: Check sheet

    private func askCheck(_ check: ArchiveCheck) async -> ArchiveCheck? {
        await settlePresentations()
        return await withCheckedContinuation { continuation in
            archiveState.checkContinuation = continuation
            archiveCheck = check
        }
    }

    /// The Import button of the check sheet.
    func confirmArchiveCheck() {
        guard let check = archiveCheck, let continuation = archiveState.checkContinuation else { return }
        archiveState.checkContinuation = nil
        archiveCheck = nil
        continuation.resume(returning: check)
    }

    func cancelArchiveCheck() {
        guard let continuation = archiveState.checkContinuation else { return }
        archiveState.checkContinuation = nil
        archiveCheck = nil
        continuation.resume(returning: nil)
    }

    /// Picks another game folder inside the archive.
    func selectArchiveCandidate(_ index: Int) {
        guard var check = archiveCheck, check.candidates.indices.contains(index) else { return }
        check.candidateIndex = index
        // The engine found for the old folder no longer applies.
        check.engineChoice = nil
        refreshSuggestedName(&check)
        archiveCheck = check
    }

    /// Reads the file names with another encoding, and looks for the game
    /// folders again.
    func setArchiveEncoding(_ encoding: ArchiveNameEncoding) {
        guard var check = archiveCheck, check.encoding != encoding else { return }
        check.encoding = encoding
        archiveCheck = check
        let id = check.id
        let listing = check.listing
        let resolved = check.resolvedEncoding
        let previousPath = check.candidate.path
        Task {
            let (layout, candidates) = await Task.detached(priority: .userInitiated) {
                let layout = ArchiveLayout(listing: listing, encoding: resolved)
                return (layout, layout.gameRootCandidates())
            }.value
            guard var current = archiveCheck, current.id == id, current.encoding == encoding else { return }
            current.layout = layout
            current.candidates = candidates
            current.candidateIndex = candidates.firstIndex { $0.path == previousPath } ?? 0
            current.engineChoice = nil
            refreshSuggestedName(&current)
            archiveCheck = current
        }
    }

    private func refreshSuggestedName(_ check: inout ArchiveCheck) {
        guard !check.folderNameEdited else { return }
        check.folderName = repository.uniqueFolderName(
            check.layout.suggestedFolderName(root: check.candidate.path, archiveURL: check.archiveURL)
        )
    }

    /// The first free name for the game folder, offered when it is taken.
    func archiveFolderNameTaken(_ name: String) -> Bool {
        repository.uniqueFolderName(name) != name
    }

    func suggestUniqueArchiveFolderName() {
        guard var check = archiveCheck else { return }
        check.folderName = repository.uniqueFolderName(check.folderName)
        check.folderNameEdited = true
        archiveCheck = check
    }

    // MARK: Questions

    /// Waits a moment so a sheet that was closing is gone before an alert or
    /// dialog is shown over the window.
    private func settlePresentations() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func askPassword(archiveName: String, wrong: Bool) async -> String? {
        await settlePresentations()
        return await withCheckedContinuation { continuation in
            archiveState.passwordContinuation = continuation
            archivePasswordRequest = ArchivePasswordRequest(archiveName: archiveName, wrong: wrong)
        }
    }

    /// The answer to the password alert; nil if the player cancelled.
    func answerArchivePassword(_ password: String?) {
        guard let continuation = archiveState.passwordContinuation else { return }
        archiveState.passwordContinuation = nil
        archivePasswordRequest = nil
        let entered = password.flatMap { $0.isEmpty ? nil : $0 }
        continuation.resume(returning: entered)
    }

    /// Shows the alert and waits; true when the first button was pressed.
    @discardableResult
    private func showArchiveAlert(_ alert: ArchiveAlert) async -> Bool {
        await settlePresentations()
        let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            archiveState.alertContinuation = continuation
            archiveAlert = alert
        }
        guard answered else { return false }
        switch alert.followUp {
        case .none: break
        case .pickArchiveAgain: showArchivePicker = true
        case .importFolder: showFolderPicker = true
        }
        return true
    }

    func answerArchiveAlert(_ primary: Bool) {
        guard let continuation = archiveState.alertContinuation else { return }
        archiveState.alertContinuation = nil
        archiveAlert = nil
        continuation.resume(returning: primary)
    }

    private func askEngine(archiveName: String, detected: [EngineID]) async -> EngineID? {
        await settlePresentations()
        return await withCheckedContinuation { continuation in
            archiveState.engineContinuation = continuation
            archiveEngineRequest = ArchiveEngineRequest(archiveName: archiveName, detected: detected)
        }
    }

    func answerArchiveEngine(_ engine: EngineID?) {
        guard let continuation = archiveState.engineContinuation else { return }
        archiveState.engineContinuation = nil
        archiveEngineRequest = nil
        continuation.resume(returning: engine)
    }

    /// The alert for a failed read or extraction.
    private func failureAlert(_ error: Error, archiveName: String, listing: Bool = false) -> ArchiveAlert {
        switch error as? ArchiveReaderError {
        case .missingPart?:
            return ArchiveAlert(
                title: String(localized: "Missing Archive Part"),
                message: error.localizedDescription,
                primary: String(localized: "Choose Again"),
                followUp: .pickArchiveAgain
            )
        case .encryptedUnsupported?:
            return ArchiveAlert(
                title: String(localized: "Can’t Open This Archive"),
                message: error.localizedDescription,
                primary: String(localized: "Import Folder"),
                cancel: String(localized: "OK"),
                followUp: .importFolder
            )
        case .notEnoughSpace(let needed, let free)?:
            return ArchiveAlert(
                title: String(localized: "Not Enough Space"),
                message: String(localized: "Extracting “\(archiveName)” needs \(AppModel.size(needed)), and \(AppModel.size(free)) is free. Remove games or saves in Settings › Storage, then try again."),
                cancel: String(localized: "OK")
            )
        case .damaged(let entry)? where !listing:
            let message = entry.map { String(localized: "“\(archiveName)” is damaged at \($0). Nothing was added. Download it again and retry.") }
                ?? String(localized: "“\(archiveName)” is damaged. Nothing was added. Download it again and retry.")
            return ArchiveAlert(
                title: String(localized: "Extraction Stopped"),
                message: message,
                primary: String(localized: "Try Again")
            )
        default:
            return ArchiveAlert(
                title: String(localized: "Can’t Open This Archive"),
                message: String(localized: "“\(archiveName)”: \(error.localizedDescription)"),
                cancel: String(localized: "OK")
            )
        }
    }

    // MARK: Extracting

    private enum ExtractionOutcome {
        case done(URL)
        case stopped
        case retry(ArchiveCheck)
    }

    /// Extracts the game and adds it to the library.
    private func extract(_ check: ArchiveCheck) async -> ArchiveJobOutcome {
        guard let result = await extractToStaging(check) else { return .skipped }
        let (extracted, staging) = result
        let added = await finish(extracted, staging: staging)
        endExtractionPresentation(success: added)
        return added ? .imported(deleteAfter: extracted.deleteAfter) : .skipped
    }

    /// Extracts the check's game folder into a new staging folder, asking
    /// again for a password or offering to retry on the way. Returns the
    /// check as it ended up (with the password that worked) and the folder,
    /// with the progress still showing; nil when it stopped.
    private func extractToStaging(_ check: ArchiveCheck) async -> (ArchiveCheck, URL)? {
        var check = check
        while true {
            switch await extractOnce(check) {
            case .done(let staging):
                return (check, staging)
            case .stopped:
                return nil
            case .retry(let updated):
                check = updated
            }
        }
    }

    private func extractOnce(_ check: ArchiveCheck) async -> ExtractionOutcome {
        let name = check.archiveURL.lastPathComponent
        let candidate = check.candidate
        let repository = self.repository
        if let free = ArchiveReader.freeSpace(at: repository.gamesRoot), candidate.byteCount > free {
            await showArchiveAlert(failureAlert(ArchiveReaderError.notEnoughSpace(needed: candidate.byteCount, free: free), archiveName: name))
            return .stopped
        }
        let staging: URL
        do {
            staging = try repository.makeStagingDirectory()
        } catch {
            alert = error.localizedDescription
            return .stopped
        }

        let relay = ExtractionRelay { [weak self] done, current in
            Task { @MainActor in self?.applyExtractionProgress(done, current) }
        }
        archiveState.relay = relay
        extraction = ArchiveExtraction(
            archiveName: name,
            engine: check.engine,
            totalBytes: candidate.byteCount,
            position: archiveState.finishedCount + 1,
            queueLength: archiveState.finishedCount + 1 + archiveState.queue.count
        )
        beginExtractionPresentation(archiveName: name, totalBytes: candidate.byteCount)
        AppDiagnostics.shared.event("library", "archive.extract.begin", ["archive": name, "bytes": String(candidate.byteCount)])

        let reader = ArchiveReader(parts: check.parts, password: check.password)
        let root = candidate.path
        let encoding = check.resolvedEncoding
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try reader.extract(root: root, encoding: encoding, into: staging) { done, current in
                    relay.report(done, current)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            return .done(staging)
        case .failure(let error):
            try? FileManager.default.removeItem(at: staging)
            endExtractionPresentation(success: false)
            AppDiagnostics.shared.event("library", "archive.extract.failed", ["archive": name, "error": error.localizedDescription])
            switch error as? ArchiveReaderError {
            case .cancelled?:
                return .stopped
            case .needsPassword?, .wrongPassword?:
                guard let entered = await askPassword(archiveName: name, wrong: check.password != nil) else { return .stopped }
                var updated = check
                updated.password = entered
                return .retry(updated)
            default:
                let retry = await showArchiveAlert(failureAlert(error, archiveName: name))
                return retry ? .retry(check) : .stopped
            }
        }
    }

    /// Detects the engine in the extracted folder, adds the game and cleans
    /// up. Returns whether a game was added.
    private func finish(_ check: ArchiveCheck, staging: URL) async -> Bool {
        let name = check.archiveURL.lastPathComponent
        let repository = self.repository
        // A game a folder deeper than expected is lifted up first.
        let detected = (try? await Task.detached(priority: .userInitiated) {
            try ArchiveStaging.liftGame(in: staging)
        }.value) ?? []

        var engine: EngineID?
        if detected.count == 1 {
            engine = detected[0]
        } else if let chosen = check.engine, detected.isEmpty || detected.contains(chosen) {
            engine = chosen
        } else {
            // The progress sheet would cover the question.
            showExtractionSheet = false
            engine = await askEngine(archiveName: name, detected: detected)
        }
        guard let engine else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }

        let folderName = repository.uniqueFolderName(check.folderName.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try await Task.detached(priority: .userInitiated) {
                try repository.adoptStagedFolder(staging, folderName: folderName, engine: engine)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: staging)
            alert = error.localizedDescription
            return false
        }
        AppDiagnostics.shared.event("library", "archive.imported", ["archive": name, "engine": engine.rawValue])

        if check.inDocuments {
            if check.deleteAfter {
                for part in check.parts { try? FileManager.default.removeItem(at: part) }
            } else {
                // Left in Documents, so it is not offered again.
                try? repository.ignoreArchive(check.archiveURL)
            }
        }

        var waited = 0
        while scanning && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        await refreshLibrary(offerNewGames: false)
        let key = GameScanner.normalized(folderName)
        if let game = games.first(where: { GameScanner.normalized($0.folderName) == key }) {
            archiveState.imported.append(game.id)
        }
        return true
    }

    private func applyExtractionProgress(_ done: Int64, _ current: String) {
        guard var running = extraction, done >= running.doneBytes else { return }
        running.doneBytes = done
        running.currentName = current
        extraction = running
        if #available(iOS 26.0, *), let task = archiveState.background as? ExtractionBackgroundTask {
            task.update(doneBytes: done)
        }
    }

    // MARK: Presenting progress

    /// Lets iOS draw the progress on iOS 26; elsewhere (or when iOS refuses)
    /// the progress sheet opens by itself, the screen stays on and a
    /// background task buys time if the player leaves.
    private func beginExtractionPresentation(archiveName: String, totalBytes: Int64) {
        var system = false
        if #available(iOS 26.0, *) {
            let relay = archiveState.relay
            let task = ExtractionBackgroundTask(archiveName: archiveName, totalBytes: totalBytes) {
                relay?.cancel()
            }
            if task.start() {
                archiveState.background = task
                system = true
            }
        }
        extraction?.systemProgress = system
        guard !system else { return }
        showExtractionSheet = true
        UIApplication.shared.isIdleTimerDisabled = true
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "Extract archive") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        archiveState.legacyTask = box
    }

    private func endExtractionPresentation(success: Bool) {
        if #available(iOS 26.0, *), let task = archiveState.background as? ExtractionBackgroundTask {
            task.finish(success: success)
        }
        archiveState.background = nil
        if let box = archiveState.legacyTask {
            if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
            box.id = .invalid
            archiveState.legacyTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        archiveState.relay = nil
        showExtractionSheet = false
        extraction = nil
    }

    /// "Stop Extracting" was confirmed: the running archive is dropped with
    /// what was written, and the ones waiting are cancelled.
    func stopExtraction() {
        AppDiagnostics.shared.event("library", "archive.extract.stopped")
        archiveState.queue.removeAll()
        archiveState.stopRequested = true
        archiveState.relay?.cancel()
    }

    // MARK: After the queue

    /// Opens the match sheet for a single new game, or the review for several.
    private func finishArchiveImports() {
        let state = archiveState
        let first = state.reviewFirst
        let added = state.imported.filter { !first.contains($0) }
        state.reviewFirst = []
        state.imported = []
        let ids = (first + added).filter { record($0) != nil }
        guard !ids.isEmpty else { return }
        if ids.count == 1, first.isEmpty, let game = record(ids[0]) {
            requestMatch(forImported: repository.gamesRoot.appendingPathComponent(game.folderName), engine: game.engine)
            return
        }
        newGamesToast = NewGamesToast(gameIDs: ids, names: ids.compactMap { record($0)?.title })
        reviewNewGames()
    }
}
