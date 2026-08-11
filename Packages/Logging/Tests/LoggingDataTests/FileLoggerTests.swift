import FileSystemDomain
import Foundation
@testable import LoggingData
import LoggingDomain
import XCTest

final class FileLoggerTests: XCTestCase {
    func testErrorUsesErrorSeverity() throws {
        let fileSystem = RecordingFileSystem()
        let logger = FileLogger(
            fileSystem: fileSystem,
            dateProvider: FixedDateProvider(),
            subsystem: "Test",
            daysOfRetention: 7
        )

        logger.error("VM failed")

        let data = try XCTUnwrap(fileSystem.writtenData)
        let message = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(message.contains(" ERROR: VM failed"))
    }
}

private struct FixedDateProvider: DateProvider {
    let now = Date(timeIntervalSince1970: 0)
}

private final class RecordingFileSystem: FileSystem {
    let applicationSupportDirectoryURL = URL(filePath: "/tmp/tartelet-logger-tests")
    private(set) var writtenData: Data?

    func createDirectoryIfNeeded(at directoryURL: URL) throws {}
    func removeItem(at itemURL: URL) throws {}
    func copyItem(from sourceItemURL: URL, to destinationItemURL: URL) throws {}

    func contentsOfDirectory(at directoryURL: URL) throws -> [URL] {
        []
    }

    func itemExists(at directoryURL: URL) -> Bool {
        false
    }

    func write(_ data: Data, toFileAt fileURL: URL) throws {
        writtenData = data
    }

    func append(_ data: Data, toFileAt fileURL: URL) throws {
        writtenData?.append(data)
    }
}
