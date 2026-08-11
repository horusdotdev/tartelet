import Darwin
import Foundation

final class SendableProcess: @unchecked Sendable {
    let process: Process
    private let terminationGracePeriod: TimeInterval
    private let lock = NSLock()
    private var cancellationRequested = false
    private var killScheduled = false

    init(_ process: Process, terminationGracePeriod: TimeInterval) {
        self.process = process
        self.terminationGracePeriod = terminationGracePeriod
    }

    func run() throws {
        try lock.withLock {
            guard !cancellationRequested else {
                throw CancellationError()
            }
            try process.run()
        }
    }

    func cancel() {
        let shouldScheduleKill = lock.withLock {
            cancellationRequested = true
            guard process.isRunning else {
                return false
            }
            process.terminate()
            guard !killScheduled else {
                return false
            }
            killScheduled = true
            return true
        }
        guard shouldScheduleKill else {
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + terminationGracePeriod
        ) { [self] in
            lock.withLock {
                guard process.isRunning else {
                    return
                }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
