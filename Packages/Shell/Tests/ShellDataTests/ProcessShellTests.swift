import Foundation
@testable import ShellData
import XCTest

final class ProcessShellTests: XCTestCase {
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
}
