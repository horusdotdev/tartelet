import Foundation
@testable import GitHubData
import GitHubDomain
import NetworkingDomain
import XCTest

final class NetworkingGitHubClientTests: XCTestCase {
    func testGetRunnerArchiveAllowsUnrelatedDownloadWithoutChecksum() async throws {
        let client = makeClient(responseJSON: """
        [
          {
            "os": "linux",
            "architecture": "x64",
            "download_url": "https://example.com/linux.tar.gz"
          },
          {
            "os": "osx",
            "architecture": "arm64",
            "download_url": "https://example.com/osx-arm64.tar.gz",
            "sha256_checksum": "abc123"
          }
        ]
        """)

        let archive = try await client.getRunnerArchive(
            with: GitHubAppAccessToken("token"),
            runnerScope: .repo
        )

        XCTAssertEqual(archive.downloadURL, URL(string: "https://example.com/osx-arm64.tar.gz"))
        XCTAssertEqual(archive.sha256Checksum, "abc123")
    }

    func testGetRunnerArchiveFailsWhenSelectedDownloadHasNoChecksum() async {
        let client = makeClient(responseJSON: """
        [
          {
            "os": "osx",
            "architecture": "arm64",
            "download_url": "https://example.com/osx-arm64.tar.gz"
          }
        ]
        """)

        do {
            _ = try await client.getRunnerArchive(
                with: GitHubAppAccessToken("token"),
                runnerScope: .repo
            )
            XCTFail("Expected the missing checksum to fail closed")
        } catch let error as NetworkingGitHubClientError {
            XCTAssertEqual(
                error.localizedDescription,
                "The download for osx (arm64) does not include a SHA-256 checksum"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(responseJSON: String) -> NetworkingGitHubClient {
        NetworkingGitHubClient(
            credentialsStore: StubGitHubCredentialsStore(),
            networkingService: StubNetworkingService(data: Data(responseJSON.utf8))
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

private final class StubNetworkingService: NetworkingService {
    private let responseData: Data

    init(data: Data) {
        responseData = data
    }

    func data(from request: URLRequest) async -> NetworkResponse<Data> {
        .success(with: responseData)
    }

    func load<T: Decodable>(
        _ valueType: T.Type,
        from request: URLRequest
    ) async -> NetworkResponse<T> {
        do {
            return .success(with: try JSONDecoder().decode(valueType, from: responseData))
        } catch {
            return .failure(withError: error)
        }
    }
}
