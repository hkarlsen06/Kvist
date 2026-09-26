import Foundation

enum SSHConnection {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    static let controlPersistSeconds = 120

    private static let controlDirectory: URL? = {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let directory = cachesDirectory
            .appendingPathComponent("Kvist/SSH", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return directory
        } catch {
            // SSH remains usable without multiplexing if the cache directory is
            // unavailable. The caller still receives the normal connection error.
            return nil
        }
    }()

    static var options: [String] {
        options(controlDirectory: controlDirectory, batchMode: true)
    }

    static func options(
        controlDirectory: URL?,
        batchMode: Bool = true
    ) -> [String] {
        var arguments: [String] = []
        if batchMode {
            arguments += ["-o", "BatchMode=yes"]
        }
        arguments += [
            "-o", "ConnectTimeout=10",
            // Drop a connection that stops answering, for example after the
            // Mac sleeps or changes networks, instead of waiting forever.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if let controlDirectory {
            arguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=\(controlPersistSeconds)",
                "-o", "ControlPath=\(controlDirectory.path)/%C"
            ]
        }
        return arguments
    }

    static func arguments(host: String, command: String) -> [String] {
        options + ["--", host, command]
    }

    /// Arguments that start `/bin/sh` on the host. The script itself goes on
    /// standard input (see `scriptInput`), so the account's login shell only
    /// has to run `/bin/sh`. csh, tcsh, and fish cannot parse sh syntax,
    /// and would otherwise reject every multi-line or quoted command.
    static func shellArguments(host: String) -> [String] {
        options + ["--", host, "/bin/sh"]
    }

    /// Marks where the script's output starts. A `.bashrc` that prints a
    /// greeting writes it before this, and `outputAfterMarker` drops it.
    static let outputMarker = "\u{1}KVIST-SSH-OUTPUT\u{1}"

    /// Standard input for `shellArguments`. The shell parses the whole
    /// `{ … }` group before running it, and `exit` on the same line ends it
    /// before it could read `input` as more script. Commands in the script
    /// read `input`, or nothing when it is nil.
    static func scriptInput(
        _ script: String,
        followedBy input: String? = nil,
        marksOutput: Bool = true
    ) -> String {
        let marker = marksOutput ? "printf '\\001KVIST-SSH-OUTPUT\\001'\n" : ""
        let redirect = input == nil ? " </dev/null" : ""
        return marker + "{\n\(script)\n}\(redirect); exit\n" + (input ?? "")
    }

    /// Drops anything the login shell printed before the script's marker.
    static func outputAfterMarker(_ data: Data) -> Data {
        guard let range = data.range(of: Data(outputMarker.utf8)) else { return data }
        return data[range.upperBound...]
    }

    static func interactiveArguments(host: String, command: String) -> [String] {
        options(controlDirectory: controlDirectory, batchMode: false)
            + ["-t", "--", host, command]
    }

    static var rsyncRemoteShell: String {
        rsyncRemoteShell(controlDirectory: controlDirectory)
    }

    static func rsyncRemoteShell(controlDirectory: URL?) -> String {
        ([executableURL.path] + options(controlDirectory: controlDirectory))
            .map(shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
