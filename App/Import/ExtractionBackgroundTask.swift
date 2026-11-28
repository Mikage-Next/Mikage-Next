import BackgroundTasks
import Foundation

/// Lets iOS 26 show and keep alive an extraction: a continued processing
/// task draws its own progress in the Dynamic Island and on the Lock Screen
/// and keeps running when the player leaves the app.
///
/// The task is registered and submitted when an extraction starts. iOS may
/// start it a moment later (or refuse); updates sent before it starts are
/// kept and applied when it does. Callers fall back to the in-app progress
/// sheet when `start()` returns false.
@available(iOS 26.0, *)
final class ExtractionBackgroundTask: @unchecked Sendable {
    let identifier: String
    private let title: String
    private let totalBytes: Int64
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var doneBytes: Int64 = 0
    private var detail = ""
    private var finished = false
    private var lastPush = Date.distantPast
    private let onExpire: @Sendable () -> Void

    /// - Parameter onExpire: called when iOS ends the task early; the caller
    ///   stops the extraction.
    init(archiveName: String, totalBytes: Int64, onExpire: @escaping @Sendable () -> Void) {
        identifier = "\(Bundle.main.bundleIdentifier ?? "app").extract.\(UUID().uuidString)"
        title = String(localized: "Extracting \(archiveName)")
        self.totalBytes = max(totalBytes, 1)
        self.onExpire = onExpire
    }

    /// Registers and submits the request. False when iOS can't run it now.
    func start() -> Bool {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] launched in
            guard let self, let continued = launched as? BGContinuedProcessingTask else { return }
            self.begin(continued)
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle(done: 0))
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    private func begin(_ continued: BGContinuedProcessingTask) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            continued.setTaskCompleted(success: true)
            return
        }
        task = continued
        continued.expirationHandler = { [weak self] in self?.onExpire() }
        continued.progress.totalUnitCount = totalBytes
        push(force: true)
    }

    /// Reports how far the extraction is. Sent to iOS at most once a second.
    func update(doneBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.doneBytes = doneBytes
        push(force: false)
    }

    /// Ends the task: the extraction finished or was stopped.
    func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let task {
            if success { task.progress.completedUnitCount = totalBytes }
            task.setTaskCompleted(success: success)
        } else {
            // iOS never started it.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    /// Must be called with the lock held.
    private func push(force: Bool) {
        guard let task, !finished else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPush) >= 1 else { return }
        lastPush = now
        task.progress.completedUnitCount = min(doneBytes, totalBytes)
        task.updateTitle(title, subtitle: subtitle(done: doneBytes))
    }

    private func subtitle(done: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return String(localized: "\(formatter.string(fromByteCount: done)) of \(formatter.string(fromByteCount: totalBytes))")
    }
}
