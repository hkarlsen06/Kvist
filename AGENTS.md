# Development Instructions

After changes affecting the runnable app, build and install the newest build to /Applications. Documentation-only or instruction-only edits do not require a rebuild or install.

When cutting a release, do not install the release build to /Applications. The installed copy stays on the previous version so the user can test that Kvist finds, shows, and installs the new release through its in-app updater once the release is published. The release steps are in [DISTRIBUTION.md](DISTRIBUTION.md).

## Build, install, and test

Install with these commands. They take about a minute:

```sh
osascript -e 'quit app "Kvist"'
KVIST_SIGNING_IDENTITY="Developer ID Application: Hjalmar Karlsen (48ZSLD4RMP)" \
  Scripts/package.sh /Applications/Kvist.app
open -a /Applications/Kvist.app
```

Quit Kvist normally rather than with `kill`, so it saves open tabs and editor drafts. `package.sh` stages the app beside the target and swaps it in, so do not `rm` or `ditto` into the bundle yourself. Without `KVIST_SIGNING_IDENTITY` the build is ad-hoc signed, and an ad-hoc install cannot use the in-app updater. If `security find-identity -v -p codesigning` lists no Developer ID identity, drop the variable to build ad-hoc and tell the user the installed copy cannot update itself. A running Kvist keeps the old code until it relaunches.

The build needs full Xcode. The asset catalog uses `actool`, which the Command Line Tools lack. If `swift build` fails on `actool`, prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and leave `xcode-select` alone.

Run tests with:

```sh
swift test > /tmp/kvist-test.log 2>&1; grep -nE "error:| failed \(|Executed [0-9]{3,} tests" /tmp/kvist-test.log | grep -v CoreData
```

The full suite has 285 XCTest cases and takes about 90 seconds. All of them pass on `main`. The last `grep` drops the `CoreData: error` lines that Contacts writes to the log. The last `Executed` line belongs to the 14-test benchmark bundle, and `Executed 0 tests` comes from swift-testing, so neither is the main suite's total. A build failure under `--filter` also prints `Executed 0 tests`. Use `swift test --filter WorkspaceTabsModelTests` while iterating. `testRepositoryModelCoalescesWorktreeEventStormIntoOneRefresh` has a timing limit and fails under load, so rerun it alone before you debug it.

The shell is zsh, so quote globs such as `--include='*.swift'`, or use `rg`.

## Where things live

All app code is in `Sources/Kvist`. Several files are large, so search for the type name instead of reading the whole file.

| Area | File and type |
| --- | --- |
| App entry, menus, ⌘W and tab-cycling key monitor, window setup | `App.swift` (`KvistApp`, `KvistAppDelegate`) |
| Tab model, recents, workspace restore | `WorkspaceTabsModel.swift` |
| Tab strip and tab dragging | `RepositoryTabBar.swift` (`RepositoryTopBar`, `RepositoryTabItem`, `TabDragState`) |
| Worktree row, status bar, panel split, editor panel | `RepositoryLayoutViews.swift` (`RepositoryWorktreeBar`, `RepositoryStatusBar`, `ActiveRepositoryView`, `RepositoryEditorPanel`) |
| Changes list, commit field, stash menu | `ChangesPanel.swift` (`ChangesPanel`, `FileSection`, `CommitMessageInput`, `SplitCommitButton`) |
| History graph and reference menus | `GraphPanel.swift` (`GraphPanel`, `GraphHistoryTable`, `GraphCommitRow`, `ReferenceContextMenuItems`) |
| Text prompts for branches, tags, stashes, and remotes | `GitPrompt.swift` (`GitPrompt`) |
| Conflict resolver | `ConflictResolverView.swift`, model in `ConflictResolution.swift` |
| Window root, welcome screen, recents, mode picker | `Views.swift` (`ContentView`, `WorkspaceView`, `WelcomeView`) |
| Theme colors and type scale | `Views.swift` (`AppTheme`, `AppType`) |
| Settings window | `ThemePreferences.swift` (`PreferencesView`, `GeneralPreferencesPane`) |
| Theme and icon-pack import | `ThemePreferences.swift` (`EditorThemeImporter`) |
| Repository state and all user actions | `RepositoryModel.swift` (`RepositoryModel`) |
| Git commands and parsing | `GitClient.swift` |
| Error dialogs | `GitClient` error to `RepositoryModel.errorPresentation`, shown by `.onChange(of: model.errorPresentation)` in `Views.swift`, then `AppDialog.swift` |
| File tree, search, editor, image and Quick Look previews | `RepositoryFileBrowser.swift`, `RepositorySearch.swift`, `RepositoryFileEditor.swift` |
| Working-tree versus HEAD preview toggle | `GitFilePreview.swift` |
| Diff rendering | `DiffDocument.swift`, `DraftDiff.swift` |
| SSH transport and remote browser | `SSHConnection.swift`, `SSHRepositoryBrowser.swift`, `SSHMirrorStore.swift` |
| Checkouts across this Mac and SSH hosts, origin matching, batched status | `Checkouts.swift` (`Checkout`, `CheckoutRegistry`), `GitClient.checkoutStatuses` |
| Checkout bar under the tab row, grouping tabs by origin | `RepositoryLayoutViews.swift` (`RepositoryWorktreeBar`), `WorkspaceTabsModel.swift` (`open(_:)`, `checkouts(shownWith:)`) |
| Repositories overview window (⌘0), Fetch All and Pull All | `RepositoryOverview.swift` |
| SSH host list, repository scan, Hosts settings pane | `SSHHosts.swift`, `ThemePreferences.swift` (`HostsPreferencesPane`) |
| Welcome screen repository list across machines | `RepositoryPicker.swift` (`PickerRepository`, `RepositoryPickerList`) |
| AI commit messages, both Codex and Claude | `CodexCommitMessageGenerator.swift`, settings in `AICommitMessagePreferences.swift` |
| In-app updater | `AppUpdater.swift` |
| Benchmark hooks inside the app | `*PerformanceInstrumentation.swift`; the harnesses are in `Sources/KvistBenchmark*` |

The bundle identifier and defaults domain are `com.hjalmarkarlsen.Kvist`.

## Modal dialogs

Use `AppDialog` (`NSAlert`) for prompts and confirmations, and `NSOpenPanel` or
`NSSavePanel` for filesystem choices. Do not implement modals with a borderless
`NSPanel` containing an `NSHostingView` and `NSApp.runModal`: when attached to
the SwiftUI window it may render correctly without receiving mouse events.

The affected input prompts are stash, create/rename branch, clone repository,
open over SSH, add/edit/link remote, and create tag. Keep them on the shared
`AppDialog` path. The “Save Changes?” prompt is the known-good reference: its
disclosure content is an `NSAlert` accessory view.

For `NSAlert` accessory forms, give text fields an explicit width and size the
accessory stack with `fittingSize`; guessed heights or intrinsic placeholder
widths clip multi-row forms. Clear the Return key equivalent on destructive
buttons unless a primary action is present.

## Tab performance benchmark

Run `Scripts/benchmark-tabs.sh` after changes to repository tabs, workspace
restoration, lazy repository loading, loading and empty states, tab switching,
repository watcher ownership, or tab-related task cancellation. The benchmark
uses 20 isolated temporary repositories and checks unopened and loaded switch
latency, rapid cycling, memory growth, main-thread stalls, idle use, and orphan
watchers, processes, or tasks.

A run takes about 4 minutes. Quit every Kvist first, and do not package,
install, or drive the UI while it runs. `Timed out waiting for
repository-loaded.json` means the benchmarked app could not present a window
because another Kvist was running or the user was active. It is not a
regression, so report it and do not retry in a loop.

One guardrail fails on `main` as of 0.5.0: Rapid-cycle footprint delta
(3.5 to 10.8 MiB between identical runs, against 3). It looks like a real
leak. A 300-cycle run settled at 18.5 MiB, so memory keeps growing with more
switches and does not level off. Do not raise that limit to make a run pass.
Judge a tab change by the unopened and loaded switch times, the main-thread
stall, and the orphan counts. If another metric fails, measure `main` the same
day before you blame the change.

## Verifying in the running app

Drive the installed app, not `.build/debug/Kvist`. A raw binary does not raise
above other windows, so synthesized clicks land elsewhere. Before clicking,
confirm Kvist is the first layer-0 window in `CGWindowListCopyWindowInfo`.
Screenshot only Kvist's window with `screencapture -x -o -l<window number>`.

- Prefer checking side effects over screenshots. `WorkspaceTabsModel` writes
  `openRepositoryPaths` and `activeRepositoryPath` to defaults as soon as a tab
  is selected or moved. `restoredWorkspaceV2` takes precedence on restore, so
  delete it when you seed tabs.
- A second instance (`open -n`) shares the user's defaults and rewrites their
  saved workspace. Run `defaults export com.hjalmarkarlsen.Kvist
  /tmp/kvist-defaults.plist` first, and afterwards delete only the keys the
  test changed.
- Read menus through the Accessibility API by PID
  (`AXUIElementCreateApplication`). AppleScript's `process whose unix id is N`
  resolves by name and can read the wrong instance. `AXPress` does not open a
  SwiftUI `Menu` button.
- `NSLog` output from the installed app is redacted in the unified log. Write
  debug output to a file in `/tmp` instead. In this shell `log` is a zsh
  function, so use `/usr/bin/log`.
- Test SSH repositories as well as local ones. Many features take a separate
  remote path.
- To test the updater, package with the Developer ID identity into a temporary
  folder and lower `CFBundleShortVersionString` below the latest release. Then
  re-sign, delete `lastUpdateCheckDate`, and launch with `open -n`.

## Writing style

Cut AI tells from all prose you write or edit, including docs, comments, release notes, and user-facing copy. Scan for the patterns below, rewrite while preserving meaning and matching the intended tone, then self-audit with "What makes this obviously AI generated?" and fix what remains. If a direct quote or a file format requires the original wording, keep it correct and apply these rules to the rest. Rule numbers are stable ids. A removed rule leaves a gap.

### Content

3. **Superficial -ing phrases.** "highlighting...", "ensuring...", "reflecting...", "showcasing...", "fostering...". Delete or expand with real sources.
5. **Vague attributions.** "Experts believe", "Industry reports suggest", "Some critics argue". Name the source or delete.

### Language

7. **AI vocabulary.** Additionally, crucial, delve, enduring, enhance, fostering, garner, interplay, intricate, landscape (abstract), pivotal, showcase, tapestry (abstract), testament, underscore, vibrant. Replace with plain words.
8. **Fancy ways to say "is".** "serves as", "stands as", "boasts", "features". Just say "is" or "has".
9. **"Not just X, but Y."** State the point directly instead.
10. **Rule of three.** Forcing ideas into groups of three. Use the natural number.
11. **Synonym cycling.** Protagonist, main character, central figure, hero all in one paragraph. Pick one, repeat it.
12. **False ranges.** "from X to Y" where X and Y aren't on a meaningful scale. List topics directly.

### Style

13. **Em dash overuse.** Avoid em dashes entirely. Use periods or commas only (no parentheses, no en dashes, no hyphen-as-dash substitutes). If a thought needs separation, end the sentence or use a comma.
14. **Colon overuse.** Colons are fine before a list or example. Not as mid-sentence connectors. "If you're coming from traditional automation: instead of registering event handlers, you describe conditions" adds nothing with the colon. Rewrite to let the point stand on its own without comparison framing. "Describing when the scheduler should fire works best as plain English." Same meaning, no crutch punctuation.
15. **Boldface overuse.** Don't bold every proper noun or acronym.
16. **Inline-header lists.** The tell is a bold label and colon that restates the line: "**Performance:** Performance improved...". Convert those to prose. A bold lead-in that ends in a period, names the item, and is followed by genuinely new detail ("**Schema in TypeScript.** Tables live in one file.") is fine, not a tell.
17. **Title case headings.** Use sentence case.
18. **Decorative emojis.** Remove from headings and bullets.
19. **Curly quotes.** Replace with straight quotes.

### Communication artifacts

20. **Chatbot phrases.** "I hope this helps!", "Let me know if...", "Of course!", "Certainly!", "Found the smoking gun!" Remove.
22. **Sycophantic tone.** "Great question! You're absolutely right!" Respond directly.

### Filler

23. **Filler phrases.** "In order to" becomes "To". "Due to the fact that" becomes "Because". "It is important to note that" gets deleted.
24. **Excessive hedging.** "could potentially possibly be argued that it might" becomes "may".
25. **Generic conclusions.** "The future looks bright." State specific plans or facts.

### Jargon

26. **Abstract metaphor nouns.** Substrate, wedge, vector, locus, vantage, nexus, primitive (as noun), harness (as metaphor), surface (as in "API surface"), bedrock, scaffolding (as metaphor), modality, paradigm, gold-plating, ratchet (as metaphor), evacuate (for moving code), endgame, north star, flywheel. These read as technical but usually have a plainer concrete word. "Substrate" becomes "base". "Wedge in" becomes "add". "Vector" becomes "way" or "method". "Gold-plating" becomes "more than the job needs". "Ratchet" becomes the mechanism's real name or "a limit that only tightens". "Evacuate" becomes "move out". "Endgame" becomes "the last phase". Pick the concrete word.

### Plain speech

27. **Say what it does, not how it feels.** "the database stays close at hand", "SQL you can read", "types that follow your schema" name a feeling. The fix names the mechanism or a number: "`.toSQL()` returns the exact string sent to the database", "a column rename fails the build". Ask what the sentence tells the reader to do or know, then write that. If you can't restate it as a concrete instruction, fact, or number, cut it. One more check: if the sentence could appear unchanged in another project's docs, it says nothing about this one. Cut it.
28. **Shorten or split dense sentences.** If the reader has to backtrack to parse a sentence, break it in two or drop clauses. One idea per sentence.
29. **Active voice.** Prefer it. Catch "is/are/was/were + past participle" and name the actor: "queries are validated" becomes "the compiler validates queries", "the file is parsed by the loader" becomes "the loader parses the file". Passive is fine only when the actor is unknown or genuinely doesn't matter.
30. **Cut adverbs, or use a stronger verb.** "runs quickly" becomes "is fast" or the number. "significantly improves" becomes the measured delta. An adverb propping up a weak verb means the verb is wrong.
31. **Prefer the plain word.** "utilize" becomes "use", "leverage" becomes "use", "facilitate" becomes "help", "numerous" becomes "many", "in the event that" becomes "if". The fancier synonym is rarely clearer.
32. **Mannered prose.** Metaphor or flourish where a literal phrase exists: aphorisms ("wire it or delete it"), rhetorical fragments for effect, personified code ("the plan holds it"), figurative verbs ("rides along", "stands on"), stock framing phrases. "A dial worth turning" becomes "a parameter worth varying". Say what you mean. Rule 26 covers the metaphor nouns.
33. **Over-compression.** Dropped articles, verbless fragments, symbol-speak, and abbreviations that make the reader decode instead of read. "Parser rejects bad date → exit 2, no write" becomes "The parser rejects a bad date, exits with code 2, and writes nothing." Write whole sentences with their articles and verbs, and spell out arrows and abbreviations.

# Bro keep going

Before you stop, ask yourself "is there a next step that the user would want me to do?" if so, keep going jobs not finished.

## Keep going without input

When a step doesn't need my input, keep going. Put status notes in the same message as your next action.
Stop and ask only when you can't continue without me, or before anything destructive: deleting data, force-pushing, or changing anything outside this repository.
