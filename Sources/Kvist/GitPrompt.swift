import AppKit
import SwiftUI

@MainActor
enum GitPrompt {
    static func stash() -> (message: String?, includeUntracked: Bool)? {
        let result = AppDialog.run(
            title: "Stash Changes",
            message: "Temporarily store staged and unstaged changes. Choose Include Untracked to stash new files too.",
            fields: [
                AppDialogField(
                    label: "Message",
                    placeholder: "Optional",
                    isRequired: false
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Tracked Changes", role: .secondary),
                AppDialogAction(title: "Include Untracked", role: .primary)
            ]
        )
        guard let actionIndex = result.actionIndex, actionIndex == 1 || actionIndex == 2 else {
            return nil
        }
        let message = result.values[0]
        return (
            message: message.isEmpty ? nil : message,
            includeUntracked: actionIndex == 2
        )
    }

    static func confirmDiscardAllChanges() -> Bool {
        let result = AppDialog.run(
            title: "Discard All Changes?",
            message: "Permanently discard every staged and unstaged change, including untracked files and folders. Ignored files are kept. This cannot be undone by Kvist.",
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Discard All", role: .destructive)
            ]
        )
        return result.actionIndex == 1
    }

    static func confirmDiscardAllUnstagedChanges() -> Bool {
        let result = AppDialog.run(
            title: "Discard All Unstaged Changes?",
            message: "Permanently discard every unstaged change, including untracked files and folders. Staged and ignored files are kept. This cannot be undone by Kvist.",
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Discard Unstaged", role: .destructive)
            ]
        )
        return result.actionIndex == 1
    }

    static func branchName(at commit: CommitInfo) -> String? {
        text(
            title: "Create Branch",
            message: "Create and check out a branch at \(commit.shortHash).",
            placeholder: "Branch name"
        )
    }

    static func branchName(from branch: String) -> String? {
        let source = branch.isEmpty || branch == "detached HEAD"
            ? "the current HEAD"
            : "\"\(branch)\""
        return text(
            title: "Create Branch",
            message: "Create and check out a branch from \(source).",
            placeholder: "Branch name"
        )
    }

    static func renamedBranch(_ reference: GitReference) -> String? {
        let result = AppDialog.run(
            title: "Rename Branch",
            message: "Rename \"\(reference.name)\". Remote branches are not renamed automatically.",
            fields: [
                AppDialogField(
                    label: "New branch name",
                    placeholder: reference.name,
                    value: reference.name
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Rename", role: .primary)
            ]
        )
        guard result.actionIndex == 1,
              let value = result.values.first,
              !value.isEmpty,
              value != reference.name else { return nil }
        return value
    }

    static func cloneRemoteURL() -> String? {
        let result = AppDialog.run(
            title: "Clone Repository",
            message: "Enter an HTTPS URL, SSH URL, or local Git repository path.",
            fields: [
                AppDialogField(
                    label: "Repository URL",
                    placeholder: "https://github.com/owner/repository.git"
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Choose Destination", role: .primary)
            ]
        )
        guard result.actionIndex == 1,
              let value = result.values.first,
              !value.isEmpty else { return nil }
        return value
    }

    static func sshRepository() -> (host: String, path: String)? {
        let result = AppDialog.run(
            title: "Open over SSH",
            message: "Kvist uses your existing SSH config and keys. Git repositories open with source control; any other folder opens as a file browser and editor. Leave the path empty to browse the remote machine's folders.",
            fields: [
                AppDialogField(label: "SSH host", placeholder: "user@example.com"),
                AppDialogField(
                    label: "Remote path",
                    placeholder: "Optional. Leave empty to browse.",
                    isRequired: false
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Connect", role: .primary)
            ]
        )
        guard result.actionIndex == 1, result.values.count == 2 else { return nil }
        return (result.values[0], result.values[1])
    }

    static func cloneDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Clone Destination"
        panel.message = "Choose the folder where the cloned repository should be created."
        panel.prompt = "Choose Destination Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func newRemote() -> (name: String, url: String)? {
        let result = AppDialog.run(
            title: "Add Remote",
            message: "Add a named remote repository.",
            fields: [
                AppDialogField(label: "Name", placeholder: "origin"),
                AppDialogField(
                    label: "Repository URL",
                    placeholder: "https://github.com/owner/repository.git"
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Add Remote", role: .primary)
            ]
        )
        guard result.actionIndex == 1,
              result.values.count == 2,
              !result.values[0].isEmpty,
              !result.values[1].isEmpty else { return nil }
        return (result.values[0], result.values[1])
    }

    static func remoteURL(for remote: GitRemote) -> String? {
        let result = AppDialog.run(
            title: "Edit Remote",
            message: "Replace the fetch URL for \"\(remote.name)\".",
            fields: [
                AppDialogField(
                    label: "Repository URL",
                    placeholder: remote.fetchURL,
                    value: remote.fetchURL
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Save", role: .primary)
            ]
        )
        guard result.actionIndex == 1,
              let value = result.values.first,
              !value.isEmpty,
              value != remote.fetchURL else { return nil }
        return value
    }

    static func tag(at commit: CommitInfo) -> (name: String, message: String?)? {
        let result = AppDialog.run(
            title: "Create Tag",
            message: "Create a tag at \(commit.shortHash). Add an annotation if this is a notable point in history.",
            fields: [
                AppDialogField(label: "Tag name", placeholder: "v1.0.0"),
                AppDialogField(
                    label: "Annotation",
                    placeholder: "Optional",
                    isRequired: false
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Create Tag", role: .primary)
            ]
        )
        guard result.actionIndex == 1 else { return nil }
        let name = result.values[0]
        guard !name.isEmpty else { return nil }
        let message = result.values[1]
        return (name, message.isEmpty ? nil : message)
    }

    static func newWorktree(defaultPath: String) -> (branch: String, path: String)? {
        let result = AppDialog.run(
            title: "New Worktree",
            message: "Check out a branch in its own folder. Kvist creates the branch from the current HEAD if it does not exist.",
            fields: [
                AppDialogField(label: "Branch", placeholder: "Branch name"),
                AppDialogField(
                    label: "Folder",
                    placeholder: "Optional. Defaults to \(defaultPath)",
                    isRequired: false
                )
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Create Worktree", role: .primary)
            ]
        )
        guard result.actionIndex == 1,
              result.values.count == 2,
              !result.values[0].isEmpty else { return nil }
        return (result.values[0], result.values[1])
    }

    static func confirmRemoveWorktree(_ worktree: GitWorktree) -> Bool {
        let branch = worktree.branch.map { " The branch \"\($0)\" stays." } ?? ""
        let result = AppDialog.run(
            title: "Remove Worktree?",
            message: "Delete the folder \(worktree.path) and close its tabs.\(branch)",
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Remove Worktree", role: .destructive)
            ]
        )
        return result.actionIndex == 1
    }

    static func confirmDelete(kind: String, name: String) -> Bool {
        let result = AppDialog.run(
            title: "Delete \(kind.capitalized)?",
            message: "Delete \"\(name)\" from this repository. This action cannot be undone by Kvist.",
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Delete", role: .destructive)
            ]
        )
        return result.actionIndex == 1
    }

    private static func text(
        title: String,
        message: String,
        placeholder: String
    ) -> String? {
        let result = AppDialog.run(
            title: title,
            message: message,
            fields: [
                AppDialogField(label: placeholder, placeholder: placeholder)
            ],
            actions: [
                AppDialogAction(title: "Cancel", role: .cancel),
                AppDialogAction(title: "Create", role: .primary)
            ]
        )
        guard result.actionIndex == 1 else { return nil }
        let value = result.values[0]
        return value.isEmpty ? nil : value
    }
}
