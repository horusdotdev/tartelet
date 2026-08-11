import Foundation
@testable import ShellData
import XCTest

final class ProcessShellTests: XCTestCase {
    func testAlreadyCancelledTaskDoesNotLaunchProcess() async throws {
        let gate = Gate()
        let markerURL = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }
        let task = Task {
            await gate.wait()
            return try await ProcessShell().runExecutable(
                atPath: "/usr/bin/touch",
                withArguments: [markerURL.path],
                environment: ProcessInfo.processInfo.environment
            )
        }
        try await waitUntil { await gate.hasWaiter }

        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testCancellationTerminatesRunningProcess() async throws {
        let task = Task {
            try await ProcessShell().runExecutable(
                atPath: "/bin/sleep",
                withArguments: ["30"],
                environment: ProcessInfo.processInfo.environment
            )
        }
        try await Task.sleep(for: .milliseconds(100))

        let clock = ContinuousClock()
        let cancellationTime = clock.now
        task.cancel()
        _ = try? await task.value

        XCTAssertLessThan(cancellationTime.duration(to: clock.now), .seconds(2))
    }

    func testCancellationKillsProcessThatIgnoresTermination() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }
        let task = Task {
            try await ProcessShell(terminationGracePeriod: 0.1).runExecutable(
                atPath: "/usr/bin/perl",
                withArguments: [
                    "-e",
                    "$SIG{TERM} = 'IGNORE'; open(my $fh, '>', $ARGV[0]); close($fh); sleep 30",
                    markerURL.path
                ],
                environment: ProcessInfo.processInfo.environment
            )
        }
        try await waitUntil {
            FileManager.default.fileExists(atPath: markerURL.path)
        }

        let clock = ContinuousClock()
        let cancellationTime = clock.now
        task.cancel()
        _ = try? await task.value

        XCTAssertLessThan(cancellationTime.duration(to: clock.now), .seconds(2))
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor Gate {
    private(set) var hasWaiter = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasWaiter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
