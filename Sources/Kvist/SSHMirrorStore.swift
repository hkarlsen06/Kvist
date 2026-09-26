import Foundation

/// Local copies of files from folders opened over SSH. Each remote location
/// has a mirror folder at `root/<id>/<name>` holding a `.kvist-ssh` marker
/// and the files downloaded for viewing and editing. Saving uploads edits
/// right away, so the downloads are only a cache.
enum SSHMirrorStore {
    static let markerName = ".kvist-ssh"

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kvist/SSH", isDirectory: true)
    }

    /// Deletes a mirror's downloaded files. The marker stays, so the Recent
    /// list can still reopen the remote location. Does nothing for a path
    /// that is not a mirror under `root`.
    static func removeDownloads(at mirrorURL: URL, root: URL = root) {
        let mirror = mirrorURL.standardizedFileURL
        let fileManager = FileManager.default
        guard mirror.path.hasPrefix(root.standardizedFileURL.path + "/"),
              fileManager.fileExists(atPath: mirror.appendingPathComponent(markerName).path),
              let items = try? fileManager.contentsOfDirectory(
                  at: mirror,
                  includingPropertiesForKeys: nil
              ) else { return }
        for item in items where item.lastPathComponent != markerName {
            try? fileManager.removeItem(at: item)
        }
    }

    /// Cleans up mirrors left by closed tabs and by earlier versions, which
    /// made a new mirror on every connection. Mirrors of open tabs are kept,
    /// mirrors in the Recent list keep only their marker, and the rest are
    /// deleted.
    static func removeUnused(
        keepingOpen openPaths: Set<String>,
        recent recentPaths: Set<String>,
        root: URL = root
    ) {
        let fileManager = FileManager.default
        guard let containers = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for container in containers {
            let mirrors = (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil
            )) ?? []
            let paths = mirrors.map(\.standardizedFileURL.path)
            if paths.contains(where: openPaths.contains) { continue }
            if paths.contains(where: recentPaths.contains) {
                mirrors.forEach { removeDownloads(at: $0, root: root) }
            } else {
                try? fileManager.removeItem(at: container)
            }
        }
    }
}
