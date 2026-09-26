# Design system

## Theme

Dark utility panel designed to stay open beside a terminal or simulator for hours, often in subdued ambient light. Ayu Dark is the default theme. One Dark Pro is built in, and users can import other editor themes.

## Color

All colors come from the active theme's palette through `AppTheme` (Views.swift); views never use raw hex values. Imported themes supply the palette, and Kvist adjusts text and graph colors until they stay readable on that theme's canvas.

The palette roles are:

- Canvas, edge and separators, input and status-strip fill, hover fill, raised chrome, diff canvas, and disabled fill
- Selection: the theme's selection color at 26% opacity
- Primary, secondary, and muted text, and text on accent surfaces
- Action blue, graph blue, and remote purple
- Modified, added and untracked, deleted, and conflict status colors
- Swift icon

## Typography

Use the macOS system font throughout, drawn from the `AppType` scale so hierarchy is consistent everywhere:

- Panel titles (CHANGES, GRAPH): 13 pt semibold, uppercase, +0.8 tracking, secondary color
- Section headers (Staged Changes, Changes): 15 pt semibold
- Row content (filenames, commit subjects): 15 pt regular; semibold marks only the HEAD commit subject
- Supporting detail (paths, branch labels): 13 pt at secondary color
- Expanded graph file rows: 13 pt with 12 pt detail
- Captions, counts, status strip: 11 to 12 pt
- Git status letters: 12 to 13 pt semibold monospaced
- Diff body: 11.5 pt monospaced

Semibold is reserved for section hierarchy and the HEAD commit subject.

## Layout

- Default width: 465 points
- Window width is otherwise unconstrained and follows normal macOS resizing.
- Default height: 886 points
- Changes occupies all flexible height above the graph.
- Graph starts at approximately 260 points and can be resized vertically with the divider.
- Major horizontal inset: 30 points
- Dense rows: 28 to 33 points
- No app toolbar, source-control title label, or permanent wide detail pane.
- A native Git/Files mode picker shares the repository tab strip.
- A 34-point bottom status strip, matching the top bar, keeps the branch, active operation, and sync state visible.
- A selected change or repository file may temporarily reveal an editor-style panel on the right, defaulting to the same width as the repository sidebar; dragging the divider resizes both panes proportionally and preserves that ratio across window sizes and launches. The window expands around its horizontal center without changing height, and Escape dismisses the panel.
- Native macOS traffic-light controls remain visible in the top-left title strip.

## Components

- Border-only commit input with blue focus treatment.
- Full-width blue split commit button.
- Inline icon-only toolbars.
- The Git/Files switcher stands alone at the leading edge of the repository action bar; Terminal and the custom folder-and-eye location menu align together at the trailing edge.
- Git concepts and repository operations use the matching Visual Studio Code Codicons; Force Push uses the native `cloud.bolt` symbol, and other platform-specific actions may use SF Symbols.
- Native macOS segmented mode picker for Git and Files, integrated into the repository tab strip.
- Editable plain-text documents use a native monospaced text view with a dirty indicator and Command-S saving.
- Git and Files each preserve their open detail panel while switching modes; Files also retains expanded folders and unsaved editor state.
- Selecting the currently open file again closes its editor or diff panel.
- Lazy repository file tree with directories collapsed by default and shared `FileGlyph` icons.
- Clickable section headers with capsule count badges and no disclosure chevrons.
- Single-line file rows with filename, path, and textual status; identical file-type glyphs everywhere via `FileGlyph`.
- Compact graph rows with blue topology marks, truncated subjects, branch pills, and no disclosure chevrons.
- Selected rows use the shared selection fill in both the Changes list and expanded graph rows.
- Welcome screen offers the primary open action, drag-and-drop folder opening, and a quiet recent-repositories list.
- Native Settings uses standard General, Themes, and Privacy & Legal tabs. AI Commit Messages settings show the provider switch and consent state. The model, Codex reasoning effort, and command template sit under Advanced. An empty model uses the latest GPT Luna model from the installed Codex CLI, or Claude Code's `sonnet` alias. Ayu Dark and Material Icon Theme are the defaults, with One Dark Pro and System Symbols available built in; discovery stays dense and source-forward, showing publisher, version, downloads, registry links, and licensing guidance without turning the utility into a marketplace.
- Workspace restoration is automatic by default and includes unsaved source drafts; recovered drafts retain their last disk version so saving can warn before overwriting a newer external edit.
