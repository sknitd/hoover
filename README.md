# Hoover

**Hover deeper. See everything.**

A native Swift/AppKit menu bar utility that adds two distinct inspection layers above real Finder items:

- **Folder X-Ray:** a deliberate three-second hover opens a spatial, recursively expandable tree. Inner folders use a short dwell, levels scroll horizontally, and live name search preserves the complete ancestry of every match within the original root.
- **File HUD:** a separate lightweight panel appears after a short file hover, with local metadata and lazy native Quick Look thumbnails.

Hoover has no user-facing demo mode, browser wrapper, analytics, or remote file inspection.

## Hoover 1.1: advanced tools

Thirty additions bring structured search, root insights, saved workspaces, keyboard navigation, and native file tools to the HUD. The full numbered inventory is in [Advanced Features](docs/Advanced-Features.md).

- Combine quoted phrases and exclusions with `kind:image`, `ext:swift,pdf`, `size:>10MB`, `modified:7d`, and `path:Sources`. Filters keep the complete ancestry inside the current root; invalid expressions explain how to fix them.
- Use **Workspace** for favorite/recent roots and reusable saved filters. Use **Insights** for counts, known sizes, file types, largest files, recent changes, and repeated filenames. Repeated names do not assert identical contents.
- Use **Tree Tools** for sorting, pinning, hidden files, refresh/reindex, folder creation, and a CSV inventory. Inventories record whether indexing had finished when the snapshot was taken.
- Right-click a card for collision-safe rename/duplicate, relative paths, file URLs, native sharing, Terminal, cancellable SHA-256, and Finder tags.
- Choose **Hover Diagnostics…** from the menu bar to see live Accessibility and item-resolution outcomes without blocking Finder hover. **Open Folder X-Ray…** also opens an explicitly chosen local folder directly.

Arrow keys navigate the tree when a text field is not being edited. **⌘G / ⇧⌘G** cycle search matches; **⇧⌘P** pins the current HUD; **⌘R** refreshes. Breadcrumbs stay within the original root. Pins prevent automatic replacement/dismissal; Escape and successful file opening still close the session.

Favorites, recent paths, and saved filters are stored only in local preferences. Recent history and saved filters can be cleared from their menus. Notes, Finder tags, rename, duplicate, and folder creation occur only after their explicit actions.

## Build the application

Requires macOS 13 or later and Xcode Command Line Tools with Swift 5.9 or later.

```sh
git clone https://github.com/sknitd/hoover.git
cd hoover
bash scripts/build-app.sh
open dist/Hoover.app
```

The script runs tests, builds both Apple Silicon and Intel binaries, creates a universal `dist/Hoover.app`, generates its layered folder icon, verifies its ad-hoc code signature, and creates `dist/Hoover-macOS.zip`. For a quicker local iteration, use `HOOVER_ARCHS="$(uname -m)" bash scripts/build-app.sh`.

An ad-hoc signature is for local use. Developer ID signing and notarization for distribution require the developer's Apple identity; the build accepts `HOOVER_SIGNING_IDENTITY` but does not embed credentials or impersonate a Developer ID.

GitHub Actions also builds, tests, and uploads the application on macOS 14 and 15. [Download the verified universal app, version 1.0.1](https://github.com/sknitd/hoover/actions/runs/37152048440/artifacts/11283914682) from the [successful native workflow](https://github.com/sknitd/hoover/actions/runs/37152048440). Unzip the downloaded artifact, then unzip its `Hoover-macOS.zip` to obtain `Hoover.app`. Both native jobs passed 66 tests, signature verification, and a launch smoke check; live Finder and visual checks remain listed in the test plan.

## First launch

Launch Hoover, then enable it in **System Settings → Privacy & Security → Accessibility**. This allows the app to identify the Finder item beneath the pointer. The permission window explains why access is needed. Hoover normally appears only in the menu bar.

Hover a real Finder folder for three seconds; hover any inner folder briefly to expand the next level. Press **⌘F** or click Search to filter only that root's subtree. The first **Esc** restores the tree; the second closes the session. **Space** opens native Quick Look. **Return** opens the focused item.

A visible Finder item can trigger Hoover while another app remains foreground, without first clicking Finder. Closing the permission window also resumes hover detection when Hoover remains foreground with no key window. Foreground Hoover settings/modal windows suppress new hover activation.

Double-click a file to open its default application. Double-click a folder to create a **new Finder window** at that folder. Successful opening dismisses Hoover's HUD. Packages such as `.app` and `.xcodeproj` open with their default applications.

Every tree card has an explicit Move to Bin action. Confirmation defaults to on, and deletion uses native macOS Trash. Context actions include Open, Open With, Quick Look, Reveal, Copy, Copy Path, Copy Filename, and Get Info.

## Settings

Configure independent folder/file delays, inner dwell, root-scoped search, hidden files/packages, optional symlink following, exclusions, themes, seven accents, opacity, density, metadata categories, notes, and launch at login. Liquid Glass defaults off and gracefully uses supported materials. Notes are stored as an extended attribute after an explicit save; file contents remain intact.

All indexing is asynchronous and cancellable, with bounded stream buffering and no fixed four-level limit. Symlink indexing defaults off and cannot follow a link beyond the original root. iCloud placeholders are not downloaded just to preview their contents.

## Develop and test

```sh
bash scripts/check-source.sh
swift run Hoover                 # macOS only
```

On Linux, the package builds and tests the platform-independent hover, directory, index, and search logic; native app sources receive syntax checks. AppKit type checking, native metadata tests, real Finder interactions, and `.app` creation require macOS.

See [Test Plan](docs/Test-Plan.md), [Evaluation](docs/Evaluation.md), [Finder Tracking](docs/Finder-Tracking.md), and [Agent Graph](docs/Agent-Graph.md). Filesystem test fixtures exist only inside tests and are never shown as product functionality.

## Architecture and reference

`HooverCore` holds portable interaction/index/search logic. `Hoover` contains Finder Accessibility tracking, transparent AppKit panels with SwiftUI cards, local type-specific extractors, settings, filesystem observation, and native file actions. The build has no third-party package dependencies.

The Finder item tracking and rich metadata design were studied against [KoukeNeko/FinderHover](https://github.com/KoukeNeko/FinderHover). Hoover's implementation is original. See [reference attribution](docs/Reference-Attribution.md) for the reference revision and licensing information.
