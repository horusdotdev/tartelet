import Foundation
import GitHubDomain
import LoggingDomain
import SSHDomain
@testable import VirtualMachineDomain
import XCTest

final class GitHubActionsRunnerSSHConnectionHandlerTests: XCTestCase {
    func testDisabledUpdatesReusePreinstalledRunnerWithoutFetchingArchive() async throws {
        let client = StubGitHubClient()
        let connection = RecordingSSHConnection()
        let handler = makeHandler(client: client, disableUpdates: true)

        try await handler.didConnect(to: StubVirtualMachine(), through: connection)

        XCTAssertEqual(client.getRunnerArchiveCallCount, 0)
        let script = try XCTUnwrap(connection.commands.first { $0.contains("cat > ~/start-runner.sh") })
        XCTAssertTrue(script.contains("Disabling runner updates pins the version installed in the base image"))
        XCTAssertTrue(script.contains("--disableupdate"))
        XCTAssertFalse(script.contains("curl --fail"))
        XCTAssertFalse(script.contains("EXPECTED_CHECKSUM"))
    }

    func testEnabledUpdatesFetchAndInstallRunnerWithRollback() async throws {
        let client = StubGitHubClient()
        let connection = RecordingSSHConnection()
        let handler = makeHandler(client: client, disableUpdates: false)

        try await handler.didConnect(to: StubVirtualMachine(), through: connection)

        XCTAssertEqual(client.getRunnerArchiveCallCount, 1)
        let script = try XCTUnwrap(connection.commands.first { $0.contains("cat > ~/start-runner.sh") })
        XCTAssertTrue(script.contains("curl --fail --location --retry 3 --retry-all-errors"))
        XCTAssertTrue(script.contains("https://example.com/actions-runner.tar.gz"))
        XCTAssertTrue(script.contains("EXPECTED_CHECKSUM=\"abc123\""))
        XCTAssertTrue(script.contains("tar xzf \\$ACTIONS_RUNNER_ARCHIVE"))
        XCTAssertTrue(
            script.contains("mv \\$ACTIONS_RUNNER_DIRECTORY \\$ACTIONS_RUNNER_BACKUP_DIRECTORY")
        )
        XCTAssertTrue(
            script.contains("mv \\$ACTIONS_RUNNER_BACKUP_DIRECTORY \\$ACTIONS_RUNNER_DIRECTORY")
        )
        XCTAssertFalse(script.contains("--disableupdate"))
    }

    private func makeHandler(
        client: StubGitHubClient,
        disableUpdates: Bool
    ) -> GitHubActionsRunnerSSHConnectionHandler {
        GitHubActionsRunnerSSHConnectionHandler(
            logger: NoopLogger(),
            client: client,
            credentialsStore: StubGitHubCredentialsStore(),
            configuration: StubRunnerConfiguration(disableUpdates: disableUpdates)
        )
    }
}

private final class StubGitHubClient: GitHubClient {
    var getRunnerArchiveCallCount = 0

    func getAppAccessToken(runnerScope: GitHubRunnerScope) async throws -> GitHubAppAccessToken {
        GitHubAppAccessToken("app-token")
    }

    func getRunnerRegistrationToken(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> GitHubRunnerRegistrationToken {
        GitHubRunnerRegistrationToken("runner-token")
    }

    func getRunnerArchive(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> GitHubRunnerArchive {
        getRunnerArchiveCallCount += 1
        return GitHubRunnerArchive(
            downloadURL: URL(string: "https://example.com/actions-runner.tar.gz")!,
            sha256Checksum: "abc123"
        )
    }
}

private final class StubGitHubCredentialsStore: GitHubCredentialsStore {
    var organizationName: String?
    var repositoryName: String? = "repo"
    var ownerName: String? = "owner"
    var appId: String?
    var privateKey: Data?

    func setOrganizationName(_ organizationName: String?) {
        self.organizationName = organizationName
    }

    func setRepository(_ repositoryName: String?, withOwner ownerName: String?) {
        self.repositoryName = repositoryName
        self.ownerName = ownerName
    }

    func setAppID(_ appID: String?) {
        appId = appID
    }

    func setPrivateKey(_ privateKeyData: Data?) {
        privateKey = privateKeyData
    }
}

private struct StubRunnerConfiguration: GitHubActionsRunnerConfiguration {
    let runnerDisableUpdates: Bool
    let runnerDisableDefaultLabels = false
    let runnerScope = GitHubRunnerScope.repo
    let runnerLabels = "self-hosted"
    let runnerGroup = "Default"
    let runnerName = "runner"

    init(disableUpdates: Bool) {
        runnerDisableUpdates = disableUpdates
    }
}

private final class RecordingSSHConnection: SSHConnection {
    var commands = [String]()

    func executeCommand(_ command: String) async throws {
        commands.append(command)
    }

    func close() async throws {}
}

private struct StubVirtualMachine: VirtualMachine {
    let name = "runner-1"
    let canStart = true

    func start() async throws {}

    func clone(named newName: String) async throws -> VirtualMachine {
        self
    }

    func delete() async throws {}

    func getIPAddress() async throws -> String {
        "127.0.0.1"
    }
}

private struct NoopLogger: Logger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
