import AppKit
import CryptoKit
import Foundation
import Security

/// Installs new releases from the GitHub releases of the Kvist repository.
/// A release qualifies when it is published, is not a prerelease, has a
/// `macos/<version>` tag, and has a `Kvist.zip` asset. The downloaded app must
/// satisfy the running app's designated requirement, so only a build signed by
/// the same Developer ID team replaces it.
@MainActor
enum AppUpdater {
    static let automaticChecksKey = "automaticallyChecksForUpdates"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/hkarlsen06/Kvist/releases?per_page=20"
    )!
    private static var isChecking = false
    static weak var workspace: WorkspaceTabsModel?
    private(set) static var isRelaunching = false

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
        }

        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var version: String? {
            tagName.hasPrefix("macos/") ? String(tagName.dropFirst(6)) : nil
        }

        var archive: Asset? {
            assets.first { $0.name == "Kvist.zip" }
        }
    }

    private enum UpdateError: LocalizedError {
        case badResponse
        case translocated
        case checksumMismatch
        case extractionFailed
        case invalidSignature
        case localBuild
        case unexpectedVersion
        case rateLimited
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .badResponse:
                "GitHub returned an unexpected response."
            case .translocated:
                "Move Kvist to the Applications folder, open it from there, and try again."
            case .checksumMismatch:
                "The downloaded archive does not match its published checksum."
            case .extractionFailed:
                "The downloaded archive could not be extracted."
            case .invalidSignature:
                "The downloaded app is not signed by the Kvist developer."
            case .localBuild:
                "This copy of Kvist is a local development build, which cannot update itself. Download the release from GitHub instead."
            case .unexpectedVersion:
                "The downloaded app has a different version than the release."
            case .rateLimited:
                "GitHub is limiting requests from this network. Try again later."
            case .operationInProgress:
                "A Git operation is still running. Try again when it finishes."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    nonisolated static func newestRelease(in releases: [Release]) -> Release? {
        releases
            .filter { !$0.draft && !$0.prerelease && $0.version != nil && $0.archive != nil }
            .max { isNewer($1.version!, than: $0.version!) }
    }

    /// Drops the update instructions, checksums, and changelog link that end
    /// every release body, along with Markdown headings, which read as noise
    /// in an alert.
    nonisolated static func releaseNotesSummary(_ body: String) -> String {
        let endings = ["Update from Kvist", "Requires macOS", "## Requirements", "SHA-256", "Full changelog"]
        return body.components(separatedBy: .newlines)
            .prefix { line in !endings.contains { line.hasPrefix($0) } }
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The notes as rich text. Inline code is monospaced, bold stays bold,
    /// and list items get a bullet with a hanging indent.
    static func releaseNotesText(_ notes: String) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 12)
        let lines = notes.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let isItem = line.hasPrefix("- ")
            let markdown = isItem ? String(line.dropFirst(2)) : line
            let parsed = (try? AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(markdown)
            let paragraph = NSMutableAttributedString(string: isItem ? "•\t" : "")
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let font: NSFont = intent.contains(.code)
                    ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                    : intent.contains(.stronglyEmphasized) ? .boldSystemFont(ofSize: 12) : body
                paragraph.append(NSAttributedString(
                    string: String(parsed[run.range].characters),
                    attributes: [.font: font]
                ))
            }
            if index < lines.count - 1 { paragraph.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = isItem ? 5 : 10
            if isItem {
                style.headIndent = 14
                style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
            }
            let whole = NSRange(location: 0, length: paragraph.length)
            paragraph.addAttribute(.paragraphStyle, value: style, range: whole)
            paragraph.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
            paragraph.enumerateAttribute(.font, in: whole) { value, range, _ in
                if value == nil { paragraph.addAttribute(.font, value: body, range: range) }
            }
            result.append(paragraph)
        }
        return result
    }

    /// A scrolling view of the notes for the update alert, as tall as the
    /// text up to a limit, so long notes keep the buttons on screen.
    static func releaseNotesView(_ notes: String) -> NSView {
        let text = releaseNotesText(notes)
        let width: CGFloat = 400
        let padding: CGFloat = 5
        let textHeight = text.boundingRect(
            with: NSSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let scrollView = NSScrollView(frame: NSRect(
            x: 0, y: 0, width: width, height: min(280, ceil(textHeight) + 12)
        ))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = padding
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(text)
        scrollView.documentView = textView
        return scrollView
    }

    static func checkAutomaticallyIfDue() {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard defaults.object(forKey: automaticChecksKey) as? Bool ?? true,
              Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 else { return }
        Task { await check(userInitiated: false) }
    }

    static func check(userInitiated: Bool) async {
        guard !isChecking else {
            if userInitiated {
                AppDialog.message(
                    title: "Checking for Updates",
                    message: "Kvist is already checking for updates."
                )
            }
            return
        }
        isChecking = true
        defer { isChecking = false }
        // Record the attempt up front so an offline Mac does not send a new
        // request every time Kvist becomes active.
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        let release: Release?
        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: break
            case 403, 429: throw UpdateError.rateLimited
            default: throw UpdateError.badResponse
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            release = newestRelease(in: try decoder.decode([Release].self, from: data))
        } catch {
            if userInitiated {
                AppDialog.message(
                    title: "Couldn't Check for Updates",
                    message: error.localizedDescription
                )
            }
            return
        }

        guard let release, let version = release.version,
              isNewer(version, than: currentVersion) else {
            if userInitiated {
                AppDialog.message(
                    title: "Kvist Is Up to Date",
                    message: "Kvist \(currentVersion) is the newest version."
                )
            }
            return
        }
        if !userInitiated,
           UserDefaults.standard.string(forKey: skippedVersionKey) == version {
            return
        }

        let notes = releaseNotesSummary(release.body ?? "")
        let result = AppDialog.run(
            title: "Kvist \(version) Is Available",
            message: "You have Kvist \(currentVersion). Kvist relaunches after the update is installed.",
            accessory: notes.isEmpty ? nil : releaseNotesView(notes),
            actions: [
                AppDialogAction(title: "Install and Relaunch", role: .primary),
                AppDialogAction(title: "Skip This Version", role: .secondary),
                AppDialogAction(title: "Not Now", role: .cancel)
            ]
        )
        switch result.actionIndex {
        case 0:
            do {
                try await install(release, version: version)
            } catch {
                AppDialog.message(
                    title: "Couldn't Install the Update",
                    message: error.localizedDescription
                )
            }
        case 1:
            UserDefaults.standard.set(version, forKey: skippedVersionKey)
        default:
            break
        }
    }

    private static func install(_ release: Release, version: String) async throws {
        let bundleURL = Bundle.main.bundleURL
        guard !bundleURL.path.contains("/AppTranslocation/") else {
            throw UpdateError.translocated
        }
        guard isDeveloperIDSigned else { throw UpdateError.localBuild }
        guard let asset = release.archive else { throw UpdateError.badResponse }
        let (archiveURL, response) = try await URLSession.shared.download(
            from: asset.browserDownloadUrl
        )
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }

        // The replacement directory sits on the same volume as the installed
        // app, so the final swap is a rename.
        let workURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: bundleURL,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: workURL) }
        let newAppURL = try await Task.detached(priority: .userInitiated) {
            try prepare(archiveURL, digest: asset.digest, version: version, in: workURL)
        }.value

        if workspace?.hasRunningOperations == true {
            throw UpdateError.operationInProgress
        }
        // Ask about unsaved files before touching the installed app, so a
        // cancelled quit leaves the old version in place.
        guard workspace?.prepareToQuit() ?? true else { return }

        _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: newAppURL)

        // Reopen the app once this process has exited.
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
            bundleURL.path
        ]
        try relauncher.run()
        // terminate exits without running the deferred cleanup.
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: workURL)
        isRelaunching = true
        NSApp.terminate(nil)
    }

    /// Ad-hoc and unsigned builds have no team identifier. Their designated
    /// requirement matches only their own code hash, so no release passes it.
    private static var isDeveloperIDSigned: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(
                  staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
              ) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] != nil
    }

    private nonisolated static func prepare(
        _ archiveURL: URL,
        digest: String?,
        version: String,
        in workURL: URL
    ) throws -> URL {
        if let digest, digest.hasPrefix("sha256:") {
            let hash = SHA256.hash(data: try Data(contentsOf: archiveURL))
                .map { String(format: "%02x", $0) }
                .joined()
            guard "sha256:\(hash)" == digest else { throw UpdateError.checksumMismatch }
        }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archiveURL.path, workURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        let appURL = workURL.appendingPathComponent("Kvist.app")
        guard ditto.terminationStatus == 0,
              FileManager.default.fileExists(atPath: appURL.path) else {
            throw UpdateError.extractionFailed
        }

        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        var newStaticCode: SecStaticCode?
        let flags = SecCSFlags(
            rawValue: UInt32(
                kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
            )
        )
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess,
              let selfStaticCode,
              SecCodeCopyDesignatedRequirement(selfStaticCode, [], &requirement)
                == errSecSuccess,
              SecStaticCodeCreateWithPath(appURL as CFURL, [], &newStaticCode)
                == errSecSuccess,
              let newStaticCode,
              SecStaticCodeCheckValidity(newStaticCode, flags, requirement)
                == errSecSuccess else {
            throw UpdateError.invalidSignature
        }

        guard Bundle(url: appURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            == version else {
            throw UpdateError.unexpectedVersion
        }
        return appURL
    }
}
