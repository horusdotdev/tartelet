import Foundation
import ShellDomain

public struct ProcessShell: Shell {
    private let terminationGracePeriod: TimeInterval

    public init() {
        terminationGracePeriod = 2
    }

    init(terminationGracePeriod: TimeInterval) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let process = Process()
        let sendableProcess = SendableProcess(
            process,
            terminationGracePeriod: terminationGracePeriod
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.arguments = arguments
            process.launchPath = executablePath
            process.standardInput = nil
            process.environment = environment
            try sendableProcess.run()
            var didWaitForExit = false
            defer {
                // Once launched, always reap the child, including when pipe handling fails.
                if !didWaitForExit {
                    process.waitUntilExit()
                }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Explicitly close the pipe file handle to prevent running out of file descriptors.
            // See https://github.com/swiftlang/swift/issues/57827
            try pipe.fileHandleForReading.close()
            process.waitUntilExit()
            didWaitForExit = true
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw ProcessShellError.unexpectedTerminationStatus(process.terminationStatus)
            }
            return String(data: data, encoding: .utf8) ?? ""
        } onCancel: {
            sendableProcess.cancel()
        }
    }
}
