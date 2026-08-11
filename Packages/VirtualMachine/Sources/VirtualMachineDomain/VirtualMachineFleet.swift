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
        isStarted = false
        isStopping = false
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks = [:]
    }

    public func stop() {
        isStopping = true
    }
}

private extension VirtualMachineFleet {
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
                stopImmediately()
            }
        }
        activeTasks[name] = task
    }

    private func runVirtualMachine(_ virtualMachine: VirtualMachine) async throws {
        try await withTaskCancellationHandler {
            logger.info("Start virtual machine named \(virtualMachine.name)")
            do {
                try await virtualMachine.start()
                logger.info("Did stop virtual machine named \(virtualMachine.name)")
                do {
                    try await virtualMachine.delete()
                    logger.info("Did delete virtual machine named \(virtualMachine.name)")
                } catch {
                    logger.info("Could not delete virtual machine named \(virtualMachine.name)")
                    throw error
                }
            } catch {
                logger.info(
                    "Virtual machine named \(virtualMachine.name) stopped with message: "
                    + error.localizedDescription
                )
                throw error
            }
        } onCancel: {
            Task.detached(priority: .high) {
                self.logger.info("Stop virtual machine named \(virtualMachine.name)")
                do {
                    try await virtualMachine.delete()
                } catch {
                    self.logger.info(
                        "Could not delete virtual machine named \(virtualMachine.name): "
                        + error.localizedDescription
                    )
                    throw error
                }
            }
        }
    }
}
