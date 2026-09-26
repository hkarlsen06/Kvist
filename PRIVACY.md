# Kvist privacy notice

Effective: September 26, 2026

Kvist does not include advertising, analytics, telemetry, or a developer-
operated account service. Repository browsing, editing, Git commands, settings,
and workspace restoration are handled locally on the Mac.

## Remote folders over SSH

When the user opens a folder over SSH, Kvist connects with the Mac's `ssh`
configuration and keys. Git commands and file searches run on the remote
machine. Files the user opens are copied to a folder in Kvist's Application
Support directory on the Mac so they can be edited, and saved edits are copied
back to the remote machine. Kvist sends no data to any other party.

## AI commit-message generation

Kvist only invokes the selected AI agent after the user presses the commit-
message generation button and accepts the provider-specific in-app disclosure.
Kvist launches a Codex or Claude command-line tool already installed and
authenticated by the user. The selected agent is instructed to read the staged
Git diff and may transmit that diff, the repository path, and any commit-message
instructions to OpenAI or Anthropic using the user's account.

Kvist does not receive a separate copy of that data. It stores the returned
commit subject locally in the repository workspace state. Use this feature only
when authorized to send the staged source code to the service configured in the
selected command-line tool. The selected provider's terms and privacy policy
govern its processing.

Kvist Settings shows the provider. The model identifier, Codex reasoning
effort, and complete command template are under Advanced, where users may edit
the command.
Kvist expands the documented placeholders, sends the generation prompt over
standard input, and runs the result through `/bin/zsh -lc` with the user's
permissions. A custom command may process or transmit data beyond Kvist's
default behavior.

For a repository opened over SSH, Kvist runs the selected command-line tool on
the remote machine under the SSH account instead. That tool must be installed
and signed in there, and its account on that machine determines where the data
goes.

Consent is stored separately for Codex and Claude and can be withdrawn in Kvist
Settings. The next attempt with that provider will show the disclosure again.

## Theme discovery

When the user searches for or imports a theme, Kvist connects directly to
the Eclipse Open VSX registry. Open VSX receives normal network information and
the search query. Imported themes remain subject to their publisher's license
and the Open VSX terms and privacy practices.

## Update checks

Unless automatic update checks are turned off in Kvist Settings, Kvist
connects to GitHub once a day to read the list of Kvist releases. Kvist also
connects when the user chooses Check for Updates. GitHub receives normal
network information. Kvist sends no repository data. When the user installs an
update, Kvist downloads the release archive from GitHub. The GitHub privacy
statement governs that processing.

## Support

Questions about this notice can be opened as an issue in the Kvist source
repository. Do not include confidential repository contents in a public issue.
