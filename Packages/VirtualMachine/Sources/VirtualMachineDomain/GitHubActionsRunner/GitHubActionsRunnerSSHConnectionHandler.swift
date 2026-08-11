import Foundation
import GitHubDomain
import LoggingDomain
import SSHDomain

private enum GitHubActionsRunnerSSHConnectionHandlerError: LocalizedError {
    case organizationNameUnavailable
    case invalidRunnerURL

    var errorDescription: String? {
        switch self {
        case .organizationNameUnavailable:
            return "The organization name is unavailable"
        case .invalidRunnerURL:
            return "The runner URL is invalid. Ensure the organization name is correct"
        }
    }
}

public struct GitHubActionsRunnerSSHConnectionHandler: VirtualMachineSSHConnectionHandler {
    private let logger: Logger
    private let client: GitHubClient
    private let credentialsStore: GitHubCredentialsStore
    private let configuration: GitHubActionsRunnerConfiguration

    public init(
        logger: Logger,
        client: GitHubClient,
        credentialsStore: GitHubCredentialsStore,
        configuration: GitHubActionsRunnerConfiguration
    ) {
        self.logger = logger
        self.client = client
        self.credentialsStore = credentialsStore
        self.configuration = configuration
    }

    // swiftlint:disable:next function_body_length
    public func didConnect(to virtualMachine: VirtualMachine, through connection: SSHConnection) async throws {
        let runnerURL = try await getRunnerURL()
        let appAccessToken = try await client.getAppAccessToken(runnerScope: configuration.runnerScope)
        let runnerToken = try await client.getRunnerRegistrationToken(
            with: appAccessToken,
            runnerScope: configuration.runnerScope
        )
        let runnerInstallation: RunnerInstallation
        if configuration.runnerDisableUpdates {
            runnerInstallation = .preinstalled
        } else {
            let runnerArchive = try await client.getRunnerArchive(
                with: appAccessToken,
                runnerScope: configuration.runnerScope
            )
            runnerInstallation = .latest(runnerArchive)
        }
        let startRunnerScriptFilePath = "~/start-runner.sh"
        try await connection.executeCommand("touch \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
cat > \(startRunnerScriptFilePath) << EOF
#!/bin/zsh
ACTIONS_RUNNER_DIRECTORY=~/actions-runner
ACTIONS_RUNNER_ARCHIVE=~/actions-runner.tar.gz.tmp
ACTIONS_RUNNER_STAGING_DIRECTORY=~/actions-runner.staging
ACTIONS_RUNNER_BACKUP_DIRECTORY=~/actions-runner.backup

# Ensure the virtual machine is restarted when a job is done.
set -e pipefail
function onexit {
  rm -f \\$ACTIONS_RUNNER_ARCHIVE
  rm -rf \\$ACTIONS_RUNNER_STAGING_DIRECTORY
  if [ -d \\$ACTIONS_RUNNER_BACKUP_DIRECTORY ] && [ ! -d \\$ACTIONS_RUNNER_DIRECTORY ]; then
    mv \\$ACTIONS_RUNNER_BACKUP_DIRECTORY \\$ACTIONS_RUNNER_DIRECTORY || true
  fi
  sudo shutdown -h now
}
trap onexit EXIT INT TERM HUP

# Wait until we can connect to GitHub.
until curl -Is https://github.com &>/dev/null; do :; done

\(runnerInstallationScript(for: runnerInstallation))

# Holds environment passed to runner. Keep host-provisioned Rust and Homebrew
# tools available even when the runner starts with a minimal PATH.
RUNNER_ENV="PATH=\\$HOME/.cargo/bin:/opt/homebrew/bin:\\$PATH\n"

# Configure pre-run script.
PRE_RUN_SCRIPT_PATH="\\$HOME/.tartelet/pre-run.sh"
if [ -f "\\$PRE_RUN_SCRIPT_PATH" ]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_STARTED=\\${PRE_RUN_SCRIPT_PATH}\n"
fi

# Configure post-run script.
POST_RUN_SCRIPT_PATH="\\$HOME/.tartelet/post-run.sh"
if [ -f "\\$POST_RUN_SCRIPT_PATH" ]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\\${POST_RUN_SCRIPT_PATH}\n"
fi

# Create the runner's .env file.
if [ "\\$RUNNER_ENV" != "" ]; then
  printf "%b" "\\$RUNNER_ENV" > \\$ACTIONS_RUNNER_DIRECTORY/.env
fi

# Configure and run the runner.
cd \\$ACTIONS_RUNNER_DIRECTORY
./config.sh\\\\
  --url "\(runnerURL)"\\\\
  --unattended\\\\
  --ephemeral\\\\
  --replace\\\\
  --labels "\(configuration.runnerLabels)"\\\\
  --name "\(runnerName(for: virtualMachine))"\\\\
  --runnergroup "\(configuration.runnerGroup)"\\\\
  --work "_work"\\\\
  --token "\(runnerToken.rawValue)"\\\\
  \(configuration.runnerDisableUpdates ? "--disableupdate" : "")\\\\
  \(configuration.runnerDisableDefaultLabels ? "--no-default-labels" : "")
./run.sh
EOF
""")
        try await connection.executeCommand("chmod +x \(startRunnerScriptFilePath)")
        try await connection.executeCommand(
            "nohup /bin/zsh \(startRunnerScriptFilePath) > ~/actions-runner.log 2>&1 < /dev/null &"
        )
    }
    private func runnerName(for virtualMachine: VirtualMachine) -> String {
        let configuredRunnerName = configuration.runnerName

        // If no custom runner name is configured, use the VM name as-is
        if configuredRunnerName.isEmpty {
            return virtualMachine.name
        }

        // Extract the index suffix from VM names like "baseVM-1", "baseVM-2"
        let vmName = virtualMachine.name
        if let lastDashIndex = vmName.lastIndex(of: "-") {
            let indexString = String(vmName[vmName.index(after: lastDashIndex)...])
            if !indexString.isEmpty, Int(indexString) != nil {
                return "\(configuredRunnerName) \(indexString)"
            }
        }
        // Fallback to just the runner name if we can't extract an index
        return configuredRunnerName
    }

    private func runnerInstallationScript(for installation: RunnerInstallation) -> String {
        switch installation {
        case .preinstalled:
            return """
            # Disabling runner updates pins the version installed in the base image.
            if [ ! -d \\$ACTIONS_RUNNER_DIRECTORY ]; then
              echo "Runner updates are disabled, but no preinstalled runner was found" >&2
              exit 1
            fi
            """
        case .latest(let archive):
            let curlCommand = "curl --fail --location --retry 3 --retry-all-errors "
                + "--output \\$ACTIONS_RUNNER_ARCHIVE \"\(archive.downloadURL)\""
            return """
            # Install the version currently offered by GitHub on every ephemeral boot.
            rm -f \\$ACTIONS_RUNNER_ARCHIVE
            rm -rf \\$ACTIONS_RUNNER_STAGING_DIRECTORY
            if [ -d \\$ACTIONS_RUNNER_BACKUP_DIRECTORY ]; then
              if [ -d \\$ACTIONS_RUNNER_DIRECTORY ]; then
                rm -rf \\$ACTIONS_RUNNER_BACKUP_DIRECTORY
              else
                mv \\$ACTIONS_RUNNER_BACKUP_DIRECTORY \\$ACTIONS_RUNNER_DIRECTORY
              fi
            fi

            \(curlCommand)

            EXPECTED_CHECKSUM="\(archive.sha256Checksum)"
            ACTUAL_CHECKSUM=\\$(shasum -a 256 \\$ACTIONS_RUNNER_ARCHIVE | awk '{print \\$1}')
            if [ "\\$ACTUAL_CHECKSUM" != "\\$EXPECTED_CHECKSUM" ]; then
              echo "GitHub Actions runner archive checksum mismatch" >&2
              exit 1
            fi

            mkdir -p \\$ACTIONS_RUNNER_STAGING_DIRECTORY
            tar xzf \\$ACTIONS_RUNNER_ARCHIVE --directory \\$ACTIONS_RUNNER_STAGING_DIRECTORY
            rm -rf \\$ACTIONS_RUNNER_BACKUP_DIRECTORY
            if [ -d \\$ACTIONS_RUNNER_DIRECTORY ]; then
              mv \\$ACTIONS_RUNNER_DIRECTORY \\$ACTIONS_RUNNER_BACKUP_DIRECTORY
            fi
            if mv \\$ACTIONS_RUNNER_STAGING_DIRECTORY \\$ACTIONS_RUNNER_DIRECTORY; then
              rm -rf \\$ACTIONS_RUNNER_BACKUP_DIRECTORY
            else
              if [ -d \\$ACTIONS_RUNNER_BACKUP_DIRECTORY ]; then
                mv \\$ACTIONS_RUNNER_BACKUP_DIRECTORY \\$ACTIONS_RUNNER_DIRECTORY
              fi
              exit 1
            fi
            rm -f \\$ACTIONS_RUNNER_ARCHIVE
            """
        }
    }
}

private enum RunnerInstallation {
    case preinstalled
    case latest(GitHubRunnerArchive)
}

private extension GitHubActionsRunnerSSHConnectionHandler {
    private func getRunnerURL() async throws -> URL {
        switch configuration.runnerScope {
        case .organization:
            let organizationName = try await getOrganizationName()
            guard let runnerURL = URL(string: "https://github.com/" + organizationName) else {
                logger.info("Invalid runner URL for organization with name \(organizationName)")
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return runnerURL
        case .repo:
            guard
                let ownerName = credentialsStore.ownerName,
                let repositoryName = credentialsStore.repositoryName,
                let runnerURL = URL(string: "https://github.com/\(ownerName)/\(repositoryName)")
            else {
                logger.info("Invalid runner URL for repository")
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return runnerURL
        }
    }

    private func getOrganizationName() async throws -> String {
        guard let organizationName = credentialsStore.organizationName else {
            logger.info("The GitHub organization name is not available")
            throw GitHubActionsRunnerSSHConnectionHandlerError.organizationNameUnavailable
        }
        return organizationName
    }
}
