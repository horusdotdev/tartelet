import Darwin
import Foundation

final class SendableProcess: @unchecked Sendable {
    let process: Process
    private let terminationGracePeriod: TimeInterval
    private let condition = NSCondition()
    private var cancellationRequested = false
    private var cleanupStarted = false
    private var cleanupFinished = true

    init(_ process: Process, terminationGracePeriod: TimeInterval) {
        self.process = process
        self.terminationGracePeriod = terminationGracePeriod
    }

    func run() throws {
        try condition.withLock {
            guard !cancellationRequested else {
                throw CancellationError()
            }
            try process.run()
        }
    }

    func cancel() {
        condition.lock()
        cancellationRequested = true
        guard process.isRunning, !cleanupStarted,
              let rootProcess = ProcessIdentity(process.processIdentifier) else {
            condition.unlock()
            return
        }
        cleanupStarted = true
        cleanupFinished = false
        var ownedProcesses = [rootProcess: 0]
        refreshOwnedProcesses(&ownedProcesses)
        process.interrupt()
        condition.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            cleanUp(ownedProcesses)
        }
    }

    func waitForCancellationCleanup() {
        condition.lock()
        while cleanupStarted, !cleanupFinished {
            condition.wait()
        }
        condition.unlock()
    }

    private func cleanUp(_ initialProcesses: [ProcessIdentity: Int]) {
        var ownedProcesses = initialProcesses
        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while Date() < deadline {
            refreshOwnedProcesses(&ownedProcesses)
            guard ownedProcesses.keys.contains(where: \.isRunning) else {
                finishCleanup()
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        refreshOwnedProcesses(&ownedProcesses)
        for process in ownedProcesses.sorted(by: { $0.value > $1.value }).map(\.key)
        where process.isRunning {
            Darwin.kill(process.pid, SIGKILL)
        }

        // Allow the kernel and the descendants' new parent time to finish reaping them.
        let reapDeadline = Date().addingTimeInterval(1)
        while Date() < reapDeadline,
              ownedProcesses.keys.contains(where: \.isRunning) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        finishCleanup()
    }

    private func finishCleanup() {
        condition.withLock {
            cleanupFinished = true
            condition.broadcast()
        }
    }
}

private struct ProcessIdentity: Hashable {
    let pid: pid_t
    private let startSeconds: UInt64
    private let startMicroseconds: UInt64

    init?(_ pid: pid_t) {
        guard let info = processInfo(for: pid) else {
            return nil
        }
        self.pid = pid
        startSeconds = info.pbi_start_tvsec
        startMicroseconds = info.pbi_start_tvusec
    }

    var isRunning: Bool {
        guard let info = processInfo(for: pid) else {
            return false
        }
        return startSeconds == info.pbi_start_tvsec
            && startMicroseconds == info.pbi_start_tvusec
    }
}

private func refreshOwnedProcesses(_ processes: inout [ProcessIdentity: Int]) {
    var pendingProcesses = Array(processes)
    while let (parent, depth) = pendingProcesses.popLast() {
        for child in childProcesses(of: parent) where processes[child] == nil {
            processes[child] = depth + 1
            pendingProcesses.append((child, depth + 1))
        }
    }
}

private func childProcesses(of parent: ProcessIdentity) -> [ProcessIdentity] {
    guard parent.isRunning else {
        return []
    }
    var childPIDs = [pid_t](repeating: 0, count: 64)
    while true {
        let childCount = childPIDs.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent.pid, buffer.baseAddress, Int32(buffer.count))
        }
        guard childCount > 0 else {
            return []
        }
        guard childCount < childPIDs.count else {
            childPIDs = [pid_t](repeating: 0, count: childPIDs.count * 2)
            continue
        }
        guard parent.isRunning else {
            return []
        }
        return childPIDs.prefix(Int(childCount)).compactMap(ProcessIdentity.init)
    }
}

private func processInfo(for pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
        return nil
    }
    return info
}
