import LoggingDomain
import Observation

@Observable
public final class VirtualMachineFleet {
    public private(set) var isStarted = false
    public private(set) var isStopping = false

    private let logger: Logger
    private let baseVirtualMachine: VirtualMachine
    private let failureRetryDelay: Duration
    private var activeTasks: [String: Task<(), Never>] = [:]

    public init(logger: Logger, baseVirtualMachine: VirtualMachine) {
        self.logger = logger
        self.baseVirtualMachine = baseVirtualMachine
        failureRetryDelay = .seconds(5)
    }

    init(logger: Logger, baseVirtualMachine: VirtualMachine, failureRetryDelay: Duration) {
        self.logger = logger
        self.baseVirtualMachine = baseVirtualMachine
        self.failureRetryDelay = failureRetryDelay
    }

    public func start(numberOfMachines: Int) {
        guard !isStarted else {
            return
        }
        guard baseVirtualMachine.canStart else {
            return
        }
        isStarted = true
        for index in 0 ..< numberOfMachines {
            let name = baseVirtualMachine.name + "-\(index + 1)"
            startSequentiallyRunningVirtualMachines(named: name)
        }
    }

    public func stopImmediately() {
        for task in beginStoppingImmediately() {
            task.cancel()
        }
        activeTasks = [:]
    }

    public func stopImmediatelyAndWait() async {
        let tasks = beginStoppingImmediately()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        activeTasks = [:]
    }

    public func stop() {
        isStopping = true
    }
}

private extension VirtualMachineFleet {
    private func beginStoppingImmediately() -> [Task<(), Never>] {
        isStarted = false
        isStopping = false
        return Array(activeTasks.values)
    }

    private func startSequentiallyRunningVirtualMachines(named name: String) {
        let task = Task {
            while !Task.isCancelled {
                do {
                    let virtualMachine = try await baseVirtualMachine.clone(named: name)
                    try await runVirtualMachine(virtualMachine)
                    if isStopping {
                        activeTasks[name]?.cancel()
                    }
                } catch {
                    guard !Task.isCancelled else {
                        continue
                    }
                    logger.error(
                        "Retrying virtual machine named \(name) in \(failureRetryDelay): "
                            + error.localizedDescription
                    )
                    try? await Task.sleep(for: failureRetryDelay)
                }
            }
            logger.info("Task running virtual machine named \(name) was cancelled.")
            activeTasks.removeValue(forKey: name)
            if activeTasks.isEmpty {
                isStarted = false
                isStopping = false
            }
        }
        activeTasks[name] = task
    }

    private func runVirtualMachine(_ virtualMachine: VirtualMachine) async throws {
        logger.info("Start virtual machine named \(virtualMachine.name)")
        let startResult: Result<Void, Error>
        do {
            try await virtualMachine.start()
            logger.info("Did stop virtual machine named \(virtualMachine.name)")
            startResult = .success(())
        } catch {
            logger.info(
                "Virtual machine named \(virtualMachine.name) stopped with message: "
                    + error.localizedDescription
            )
            startResult = .failure(error)
        }

        // Cleanup must not inherit cancellation from the fleet task. Keep the cleanup task
        // owned and awaited so application termination cannot finish while deletion is in flight.
        do {
            try await Task.detached(priority: .high) {
                try await virtualMachine.delete()
            }.value
            logger.info("Did delete virtual machine named \(virtualMachine.name)")
        } catch {
            logger.info(
                "Could not delete virtual machine named \(virtualMachine.name): "
                    + error.localizedDescription
            )
            if case .success = startResult {
                throw error
            }
        }

        try startResult.get()
    }
}
