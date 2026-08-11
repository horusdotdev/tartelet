import LoggingDomain
import SSHDomain
@testable import VirtualMachineDomain
import XCTest

final class SSHConnectingVirtualMachineTests: XCTestCase {
    func testStartFailurePreservesCauseAndDoesNotLogSiblingCancellationAsIPAddressFailure() async {
        let logger = ThreadSafeRecordingLogger()
        let virtualMachine = ImmediatelyFailingVirtualMachine()
        let sshClient = VirtualMachineSSHClient(
            logger: logger,
            client: UnusedSSHClient(),
            ipAddressReader: WaitingIPAddressReader(),
            credentialsStore: StubCredentialsStore(),
            connectionHandler: NoopConnectionHandler()
        )
        let subject = SSHConnectingVirtualMachine(
            logger: logger,
            virtualMachine: virtualMachine,
            sshClient: sshClient
        )

        do {
            try await subject.start()
            XCTFail("Expected virtual machine startup to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Failed starting virtual machine: tart run failed with status 1"
            )
        }
        XCTAssertFalse(
            logger.errorMessages.contains { $0.contains("Failed obtaining IP address") }
        )
    }
}

private struct ImmediatelyFailingVirtualMachine: VirtualMachine {
    let name = "runner-1"
    let canStart = true

    func start() async throws {
        throw SSHConnectingTestError.startFailed
    }

    func clone(named newName: String) async throws -> VirtualMachine {
        self
    }

    func delete() async throws {}

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }
}

private struct WaitingIPAddressReader: VirtualMachineIPAddressReader {
    func readIPAddress(of virtualMachine: VirtualMachine) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "127.0.0.1"
    }
}

private struct UnusedSSHClient: SSHClient {
    func connect(host: String, username: String, password: String) async throws -> NoopSSHConnection {
        NoopSSHConnection()
    }
}

private struct NoopSSHConnection: SSHConnection {
    func executeCommand(_ command: String) async throws {}
    func close() async throws {}
}

private final class StubCredentialsStore: VirtualMachineSSHCredentialsStore {
    var username: String? = "admin"
    var password: String? = "admin"

    func setUsername(_ username: String?) {
        self.username = username
    }

    func setPassword(_ password: String?) {
        self.password = password
    }
}

private struct NoopConnectionHandler: VirtualMachineSSHConnectionHandler {
    func didConnect(to virtualMachine: VirtualMachine, through connection: SSHConnection) async throws {}
}

private enum SSHConnectingTestError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        "tart run failed with status 1"
    }
}

private final class ThreadSafeRecordingLogger: Logger {
    private let lock = NSLock()
    private var errors: [String] = []

    var errorMessages: [String] {
        lock.withLock { errors }
    }

    func info(_ message: String) {}

    func error(_ message: String) {
        lock.withLock {
            errors.append(message)
        }
    }
}
