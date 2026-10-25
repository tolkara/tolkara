// Finite, user-started IPC validation. Never manufacture progress or resubmit
// expired tasks: this experiment does not promise indefinite background service.
import BackgroundTasks
import Foundation

final class ContinuedProbe {
    static let shared = ContinuedProbe()
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var registered = false
    private var pending = false
    private var replyTarget: Int64 = 120
    private var message = "not started"
    private let identifier = Bundle.main.bundleIdentifier! + ".validation"

    func status() -> String { lock.lock(); defer { lock.unlock() }; return message }

    private func record(_ text: String) {
        message = text
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("continued-probe.log")
        let data = Data("\(Date()) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }

    // Called only from the visible Start button.
    func start(replies: Int64 = 120) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil, !pending, replies == 120 || replies == 600 else { return }
        replyTarget = replies
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { incoming in
                guard let task = incoming as? BGContinuedProcessingTask else {
                    incoming.setTaskCompleted(success: false); return
                }
                self.lock.lock(); defer { self.lock.unlock() }
                task.progress.totalUnitCount = self.replyTarget
                task.expirationHandler = { self.finish(success: false, reason: "expired or cancelled") }
                self.task = task
                self.pending = false
                self.record("running: 0/\(self.replyTarget) successful replies")
            }
        }
        guard registered else { record("registration refused"); return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: "Validate two-app communication", subtitle: "\(replyTarget) successful replies")
        request.strategy = .fail
        do { pending = true; try BGTaskScheduler.shared.submit(request); record("submitted") }
        catch { pending = false; record("submission failed: \(error)") }
    }

    func replied() {
        lock.lock()
        guard let task else { lock.unlock(); return }
        task.progress.completedUnitCount += 1
        let count = task.progress.completedUnitCount
        record("reply \(count)/\(replyTarget)")
        let complete = count >= replyTarget
        if complete { self.task = nil; record("completed \(count)/\(replyTarget)") }
        lock.unlock()
        if complete { task.setTaskCompleted(success: true) }
    }

    private func finish(success: Bool, reason: String) {
        lock.lock()
        let ending = task; task = nil; pending = false; record(reason)
        lock.unlock()
        ending?.setTaskCompleted(success: success)
    }
}
