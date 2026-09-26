import Foundation
import XCTest
@testable import Kvist

final class AICommitMessagePreferencesTests: XCTestCase {
    func testAICommitMessageSSHCommandUsesRemoteRepository() throws {
        let repository = try SSHRepository(
            host: "deploy@example.com",
            path: "/srv/project with spaces"
        )

        let arguments = SSHConnection.shellArguments(host: repository.host)
        let script = AICommitMessageGenerator.remoteShellScript(
            for: repository,
            command: "codex exec"
        )

        XCTAssertEqual(arguments, SSHConnection.options + ["--", "deploy@example.com", "/bin/sh"])
        XCTAssertEqual(script, "cd '/srv/project with spaces' && codex exec")
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("ControlPersist=120"))
    }

    func testAICommitMessageSSHCommandRunsInALoginShell() throws {
        let repository = try SSHRepository(host: "deploy@example.com", path: "/srv/app")

        let command = AICommitMessageGenerator.remoteShellScript(
                for: repository,
                command: "claude --print",
                inLoginShell: true
            )

        XCTAssertTrue(command.hasPrefix("cd '/srv/app' && "))
        XCTAssertTrue(command.contains("-l -c 'claude --print'"))
        // fish and tcsh cannot parse the `sh` script Kvist sends.
        XCTAssertTrue(command.contains("bash|zsh|sh|ksh|dash|ash"))
    }

    /// The remote command runs in a non-interactive shell, which does not read
    /// `.bashrc` or `.zshrc`, so a CLI installed under `$HOME` used to fail with
    /// "claude: command not found".
    func testRemotePathPreambleFindsCLIInstalledUnderHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kvist-remote-path-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )
        let executable = binDirectory.appendingPathComponent("claude")
        try "#!/bin/sh\necho stub\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let repository = try SSHRepository(host: "example.com", path: home.path)
        let remoteCommand = AICommitMessageGenerator.remoteShellScript(
                for: repository,
                command: """
                \(AICommitMessageGenerator.remotePathPreamble)
                command -v claude
                """,
                inLoginShell: true
            )

        let result = try AICommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["-i", "HOME=\(home.path)", "PATH=/usr/bin:/bin", "SHELL=/bin/sh", "/bin/sh", "-c", remoteCommand],
            currentDirectoryURL: nil,
            standardInput: nil,
            timeout: 20
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(
            result.output.contains(executable.resolvingSymlinksInPath().path)
                || result.output.contains(executable.path),
            result.output
        )
    }

    func testRemoteScriptRunsACLIInstalledUnderHomeAndReportsAMissingOne() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kvist-remote-script-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )
        let stub = binDirectory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        cat > /dev/null
        echo '{"message":"feat: add stub"}'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stub.path
        )

        let directory = home.appendingPathComponent("run", isDirectory: true).path
        func run(_ executableName: String) throws -> ProcessResult {
            let script = AICommitMessageGenerator.remoteScript(
                executableName: executableName,
                command: "\(executableName) --print",
                directory: directory,
                schemaPath: "\(directory)/commit-message.schema.json",
                outputPath: "\(directory)/commit-message.json",
                logPath: "\(directory)/command.log"
            )
            let repository = try SSHRepository(host: "example.com", path: home.path)
            let remoteCommand = AICommitMessageGenerator.remoteShellScript(
                for: repository,
                command: script,
                inLoginShell: true
            )
            return try AICommandRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [
                    "-i",
                    "HOME=\(home.path)",
                    "PATH=/usr/bin:/bin",
                    "SHELL=/bin/sh",
                    "/bin/sh",
                    "-c",
                    remoteCommand
                ],
                currentDirectoryURL: nil,
                standardInput: "diff",
                timeout: 30
            )
        }

        let found = try run("claude")
        XCTAssertEqual(found.exitCode, 0, found.output)
        XCTAssertTrue(found.output.contains("{\"message\":\"feat: add stub\"}"), found.output)

        let missingName = "kvist-missing-cli-\(UUID().uuidString)"
        let missing = try run(missingName)
        XCTAssertEqual(missing.exitCode, 127, missing.output)
        XCTAssertTrue(missing.output.contains("\(missingName): command not found"), missing.output)
        XCTAssertTrue(missing.output.contains("Remote PATH:"), missing.output)
    }

    func testCommandRunnerSurvivesChildThatExitsBeforeReadingStandardInput() throws {
        // A child that exits without draining stdin — an `ssh` that cannot connect,
        // a provider command that fails immediately — used to kill the whole app
        // with SIGPIPE on the write, so a regression terminates this test process.
        let result = try AICommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.2; echo failed early >&2; exit 3"],
            currentDirectoryURL: nil,
            standardInput: String(repeating: "x", count: 200_000),
            timeout: 30
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.output.contains("failed early"))
    }

    func testConfigurationKeepsProviderSpecificModelsAndCommands() throws {
        let suiteName = "AICommitMessagePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            AICommitMessageProvider.claude.rawValue,
            forKey: AICommitMessagePreferences.providerKey
        )
        defaults.set("claude-opus-4-6", forKey: AICommitMessagePreferences.claudeModelKey)
        defaults.set("custom {model}", forKey: AICommitMessagePreferences.claudeCommandTemplateKey)
        defaults.set("gpt-custom", forKey: AICommitMessagePreferences.codexModelKey)

        let configuration = AICommitMessageConfiguration.load(defaults: defaults)

        XCTAssertEqual(configuration.provider, .claude)
        XCTAssertEqual(configuration.model, "claude-opus-4-6")
        XCTAssertNil(configuration.reasoningEffort)
        XCTAssertEqual(configuration.commandTemplate, "custom {model}")
    }

    func testCodexDefaultsToAutomaticModelAtLowEffort() throws {
        let suiteName = "KvistTests.AIDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(AICommitMessageConfiguration.load(defaults: defaults).model)

        // The model Kvist used to store as its default now follows the latest Luna.
        defaults.set("gpt-6-luna", forKey: AICommitMessagePreferences.codexModelKey)
        let configuration = AICommitMessageConfiguration.load(defaults: defaults)

        XCTAssertEqual(configuration.provider, .codex)
        XCTAssertNil(configuration.model)
        XCTAssertEqual(configuration.reasoningEffort, .low)
    }

    func testAutomaticModelPicksHighestPriorityLuna() {
        let catalog = [
            AICommitMessageModel(id: "gpt-7-sol", name: "Sol"),
            AICommitMessageModel(id: "gpt-7-luna", name: "Luna"),
            AICommitMessageModel(id: "gpt-6-luna", name: "Old Luna")
        ]

        XCTAssertEqual(AICommitMessageProvider.codex.automaticModel(in: catalog), "gpt-7-luna")
        XCTAssertEqual(
            AICommitMessageProvider.codex.automaticModel(in: Array(catalog.prefix(1))),
            "gpt-7-sol"
        )
        XCTAssertNil(AICommitMessageProvider.codex.automaticModel(in: []))
        XCTAssertEqual(AICommitMessageProvider.claude.automaticModel(in: []), "sonnet")
    }

    func testCodexConfigurationLoadsReasoningEffortAndMigratesLegacyDefault() throws {
        let suiteName = "AICommitMessagePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            AICommitMessageProvider.codex.rawValue,
            forKey: AICommitMessagePreferences.providerKey
        )
        defaults.set(
            AICommitMessageReasoningEffort.max.rawValue,
            forKey: AICommitMessagePreferences.codexReasoningEffortKey
        )
        defaults.set(
            AICommitMessageProvider.codex.legacyDefaultCommandTemplate,
            forKey: AICommitMessagePreferences.codexCommandTemplateKey
        )

        let configuration = AICommitMessageConfiguration.load(defaults: defaults)

        XCTAssertEqual(configuration.reasoningEffort, .max)
        XCTAssertEqual(
            configuration.commandTemplate,
            AICommitMessageProvider.codex.defaultCommandTemplate
        )
    }

    func testCodexModelCatalogUsesVisibleModelsInPriorityOrder() throws {
        let output = """
        warning: cached catalog
        {"models":[
          {"slug":"hidden","display_name":"Hidden","visibility":"hide","priority":0},
          {"slug":"fast","display_name":"Fast","visibility":"list","priority":2},
          {"slug":"best","display_name":"Best","visibility":"list","priority":1,"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}]}
        ]}
        """

        XCTAssertEqual(
            try AICommitMessageModelCatalog.parseCodexModels(output),
            [
                AICommitMessageModel(
                    id: "best",
                    name: "Best",
                    supportedReasoningEfforts: [.low, .medium, .high],
                    defaultReasoningEffort: .medium
                ),
                AICommitMessageModel(id: "fast", name: "Fast")
            ]
        )
    }

    func testCommandTemplateShellQuotesUserControlledValues() throws {
        let command = try AICommitMessageGenerator.expandCommandTemplate(
            "{executable} --model {model} --effort {reasoning-effort} --cd {repository}",
            executableURL: URL(fileURLWithPath: "/tmp/agent"),
            model: "model'; touch /tmp/should-not-run; '",
            reasoningEffort: .xhigh,
            repositoryURL: URL(fileURLWithPath: "/tmp/repo name"),
            schemaURL: URL(fileURLWithPath: "/tmp/schema"),
            outputURL: URL(fileURLWithPath: "/tmp/output")
        )

        XCTAssertEqual(
            command,
            "'/tmp/agent' --model 'model'\"'\"'; touch /tmp/should-not-run; '\"'\"'' --effort 'xhigh' --cd '/tmp/repo name'"
        )
    }
}
