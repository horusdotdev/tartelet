import LoggingDomain
@testable import VirtualMachineDomain
import XCTest

final class VirtualMachineFleetTests: XCTestCase {
    func testStartFailureIsBackedOffBeforeRetrying() async throws {
        let virtualMachine = FailingVirtualMachine()
        let fleet = VirtualMachineFleet(
            logger: RecordingLogger(),
            baseVirtualMachine: virtualMachine,
            failureRetryDelay: .seconds(10)
        )

        fleet.start(numberOfMachines: 1)
        try await waitUntil { await virtualMachine.cloneCount == 1 }
        try await Task.sleep(for: .milliseconds(100))

        let cloneCount = await virtualMachine.cloneCount
        let deleteCount = await virtualMachine.deleteCount
        XCTAssertEqual(cloneCount, 1)
        XCTAssertEqual(deleteCount, 1)
        await fleet.stopImmediatelyAndWait()
    }

    func testStopImmediatelyAndWaitCancelsRunningVirtualMachine() async throws {
        let virtualMachine = LongRunningVirtualMachine()
        let fleet = VirtualMachineFleet(
            logger: RecordingLogger(),
            baseVirtualMachine: virtualMachine,
            failureRetryDelay: .seconds(10)
        )

        fleet.start(numberOfMachines: 1)
        try await waitUntil { await virtualMachine.didStart }
        await fleet.stopImmediatelyAndWait()

        let wasCancelled = await virtualMachine.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testStopImmediatelyAndWaitDoesNotReturnBeforeCleanupFinishes() async throws {
        let virtualMachine = ControlledCleanupVirtualMachine()
        let fleet = VirtualMachineFleet(
            logger: RecordingLogger(),
            baseVirtualMachine: virtualMachine,
            failureRetryDelay: .seconds(10)
        )
        let stopState = StopState()

        fleet.start(numberOfMachines: 1)
        try await waitUntil { await virtualMachine.didStart }
        let stopTask = Task {
            await fleet.stopImmediatelyAndWait()
            await stopState.recordCompletion()
        }
        try await waitUntil { await virtualMachine.deleteStarted }

        let completedBeforeDeletion = await stopState.completed
        XCTAssertFalse(completedBeforeDeletion)
        await virtualMachine.finishDeletion()
        await stopTask.value

        let deleteFinished = await virtualMachine.deleteFinished
        let completedAfterDeletion = await stopState.completed
        XCTAssertTrue(deleteFinished)
        XCTAssertTrue(completedAfterDeletion)
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

private actor StopState {
    private(set) var completed = false

    func recordCompletion() {
        completed = true
    }
}

private actor ControlledCleanupVirtualMachine: VirtualMachine {
    let name = "base"
    let canStart = true
    private(set) var didStart = false
    private(set) var deleteStarted = false
    private(set) var deleteFinished = false
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        didStart = true
        try await Task.sleep(for: .seconds(30))
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        self
    }

    func delete() async throws {
        deleteStarted = true
        await withCheckedContinuation { continuation in
            deleteContinuation = continuation
        }
        deleteFinished = true
    }

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }

    func finishDeletion() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }
}

private actor LongRunningVirtualMachine: VirtualMachine {
    let name = "base"
    let canStart = true
    private(set) var didStart = false
    private(set) var wasCancelled = false

    func start() async throws {
        didStart = true
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(30))
        } onCancel: {
            Task {
                await self.recordCancellation()
            }
        }
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        self
    }

    func delete() async throws {}

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }

    private func recordCancellation() {
        wasCancelled = true
    }
}

private actor FailingVirtualMachine: VirtualMachine {
    let name = "base"
    let canStart = true
    private(set) var cloneCount = 0
    private(set) var deleteCount = 0

    func start() async throws {
        throw TestError.startFailed
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        cloneCount += 1
        return self
    }

    func delete() async throws {
        deleteCount += 1
    }

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }
}

private enum TestError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        "tart run failed with status 1"
    }
}

private final class RecordingLogger: Logger {
    private(set) var infoMessages: [String] = []
    private(set) var errorMessages: [String] = []

    func info(_ message: String) {
        infoMessages.append(message)
    }

    func error(_ message: String) {
        errorMessages.append(message)
    }
}
