# Hoover validation plan

The evaluator follows requirements → build/tests → findings → repair → recheck. Test fixtures exist only in test targets and never ship as a product mode. See [Agent-Graph.md](Agent-Graph.md) for ownership and feedback loops.

## Automated checks

Run `bash scripts/check-source.sh` with Swift on PATH. On Linux this runs the portable core tests and parses native Swift syntax; it cannot type-check Apple frameworks. On macOS it also builds the native executable.

Run `bash scripts/stress-core.sh` for the optional large-tree core evaluation. It compiles optimized real core sources, creates 100,000 temporary real files, verifies record and match/ancestry counts, prints indexing/query timings, and removes its fixtures. This is a developer test script, not a user-facing application mode.

Run `bash scripts/build-app.sh` on a Mac with Xcode Command Line Tools. This runs all portable and macOS tests, builds arm64 and x86_64 release executables, creates the icon, assembles the real app, signs it, verifies the signature, checks executable architecture, and writes `dist/Hoover-macOS.zip`. Set `HOOVER_ARCHS="$(uname -m)"` for a quicker development build. Signing is ad hoc unless `HOOVER_SIGNING_IDENTITY` selects an installed signing identity. Distribution notarization requires the developer's signing credentials and is separate from local builds.

The GitHub workflow tests and packages on macOS 14 and 15, with a separate Linux core job. macOS rendering tests export four real native UI snapshots when `HOOVER_SNAPSHOT_DIR` is set: dark hierarchy, light hierarchy, filtered ancestry, and a source-file HUD. Their temporary filesystem is real; the plain snapshot background is a test harness, not simulated Finder. Snapshots do not verify Accessibility item detection or interactive behavior.

CI opts into native action tests using `HOOVER_NATIVE_ACTION_TESTS=1`: disposable test-owned files/folders move through real native Trash, then cleanup targets only the exact returned destination URL. Clipboard checks preserve accessible prior representations in memory. `HOOVER_LAUNCH_SMOKE_TEST=1` starts the packaged binary, checks its launch marker and process survival, and stops only that process. Local builds omit these explicit side-effect checks unless requested through those variables.

Automated coverage includes dwell cancellation and blocked interactions, separate folder/file delays, dismissal suppression, two-step Escape, deep ancestry, multiple matches, ranking, Unicode normalization, root boundaries, exclusions, hidden/package options, symlink loops and root escapes, directory errors, cancellation, bounded lossless index streaming, text/configuration parsing, metadata read limits, note preservation, literal subprocess arguments, time/output limits, ZIP no-extraction behavior, native image/PDF metadata, settings defaults/clamping, and native view rendering.

## Required interactive macOS checks

Use a disposable folder containing real files with these paths, and add a second matching file under a different branch. Enable Accessibility for the built Hoover app in System Settings; grant Finder Automation when explicitly opening a folder. These system grants cannot be replaced by a chat permission statement.

```
EdgeDock-source/
├── docs/
├── EdgeDock/
│   ├── Core/DockController.swift
│   └── Views/Config.swift
├── Tests/ConfigTests.swift
├── scripts/
├── README.md
├── statement.pdf
├── photo.jpg
└── archive.zip
```

| Check | Action | Required result |
| --- | --- | --- |
| A | Hover `EdgeDock-source` in Finder for 3 seconds without pressing a key | Folder X-Ray opens from that exact hovered item; direct children form Level 1; Finder remains visible. Passing over it or leaving early cancels activation. |
| B | Hover the `EdgeDock` card | Level 2 opens after the configured inner dwell, approximately 300 ms. Leaving the card early cancels it. |
| C | Hover `Core`, then further real nested folders beyond Level 4 | Every level opens; trackpad and Shift+wheel navigate horizontally; new levels scroll into view without screen clipping. |
| D | Press ⌘F and type `DockController` one character at a time | Immediate local subtree filtering; unrelated branches dissolve; full root → EdgeDock → Core → file ancestry remains. Searching `swift`, `README.md`, folder names, and `Config` also works. Multiple matching branches remain simultaneously. |
| E | Press Escape twice during search | First restores the normal tree and dismisses search; second dismisses the entire overlay. Escape outside search dismisses in one step. A stationary pointer does not reopen it immediately. |
| F | Hover `statement.pdf` | A separate File HUD opens after approximately 600 ms, with native thumbnail and page metadata; no folder levels appear. |
| G | Hover a real JPEG/HEIC/CR3 with known camera/GPS metadata | Image dimensions and available EXIF/IPTC/XMP appear. Missing camera/HDR information is not invented. Unsupported RAW thumbnail support is shown honestly. |
| H | Hover a ZIP with nested names and an encrypted-entry variant | Counts, contents, declared encryption, and compression totals appear without extracting anything. Unsupported archive features are labeled unavailable/partial. |
| I | Click `README.md`'s Bin icon, cancel, then confirm a second attempt | Cancel preserves it. Confirm uses recoverable native Trash; node/index/metadata update. Trashing an explored ancestor collapses its descendants. Failure preserves the tree and shows an error. |
| J | Double-click a file, then a folder, in both normal and filtered HUD/tree paths | File opens with its registered default application. Folder opens in a **new Finder window** targeting that folder. Successful opening dismisses the HUD. Automation denial produces a useful error and does not claim success. |

Repeat A, F, and J in Finder icon, list, column, and gallery views, including hidden extensions, localized filenames, spaces, quotes, and Unicode. Test earlier columns while a different final column is selected. Hovering toolbar/sidebar/search controls or empty Finder background must not resolve a selected file elsewhere.

## Session, safety, and appearance checks

- Rename, drag, context menus, Finder window disappearance, and app switching cancel inappropriate hover activation and dismiss stale file HUDs. Move from the Finder root across the connector into cards without losing the folder session.
- Root remains fixed throughout search. Symlinks never traverse outside it, even when following links is enabled; exclusions prune descendants before reading them. Test restricted folders, iCloud placeholders, external/network volume exclusions, and empty folders without repeated permission prompts or implicit downloads.
- Create, rename, or remove a **deep, previously unexpanded** descendant while a root session is open; search must update through recursive filesystem observation. Selection should remain stable when unaffected. Dismissal releases watchers and indexing work.
- Test Quick Look from Space/button/context menu and Return opening. Search fields and note editors must receive typing normally; Space/Return cannot open files while editing. Note save/remove preserves file contents; disabled notes hide the editor.
- Check real file dragging to Finder/Desktop/Mail, Open With, Reveal, Copy, Copy Path/Name, Get Info, and restore trashed fixtures from Finder. File operations never invoke a shell with a user path.
- Inspect both visual themes and all accents, compact/rich HUD, density/text sizes, opacity/glow, and setting persistence. Liquid Glass defaults off; unavailable native glass uses standard translucent materials. Confirm no Dock icon or Demo Mode.
- Test two displays arranged left/right and vertically, different scale factors, Spaces/fullscreen Finder, narrow screens, and root items near each edge. Interaction passes through transparent overlay areas while cards/search remain clickable.
- Exercise 10, 1,000, and 100,000 descendants. Record first streamed batch, index completion, per-query latency, UI interaction latency, peak resident memory, cancellation delay, and CPU while idle. Broad matching remains virtualized and never blocks the main thread. Linux core timings are supporting evidence, not a substitute for macOS rendering measurements.

Record platform, app commit, permissions, results, screenshots, and any skipped cases in [Evaluation.md](Evaluation.md). Do not mark native behavior as passed from source inspection or Linux syntax parsing alone.
