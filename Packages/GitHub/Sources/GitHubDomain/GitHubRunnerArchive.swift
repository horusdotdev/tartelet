import Foundation

public struct GitHubRunnerArchive: Equatable, Sendable {
    public let downloadURL: URL
    public let sha256Checksum: String

    public init(downloadURL: URL, sha256Checksum: String) {
        self.downloadURL = downloadURL
        self.sha256Checksum = sha256Checksum
    }
}
