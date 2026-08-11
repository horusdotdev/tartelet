import Foundation

public struct GitHubRunnerDownload: Codable {
    private enum CodingKeys: String, CodingKey {
        case os
        case architecture
        case downloadURL = "download_url"
        case sha256Checksum = "sha256_checksum"
    }

    let os: String
    let architecture: String
    let downloadURL: URL
    let sha256Checksum: String?
}
