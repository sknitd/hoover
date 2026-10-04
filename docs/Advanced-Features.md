# Hoover advanced feature acceptance inventory

This inventory covers the thirty advanced features requested for the native Hoover app. Implementation and verification results are tracked separately in [Advanced-Evaluation.md](Advanced-Evaluation.md). Existing Finder hover, file HUD, two-step search Escape, and double-click opening remain acceptance requirements throughout the expansion.

Search and insights use the active folder's indexed descendants. Filtering, sorting, and breadcrumb navigation must preserve that session's root. Explicitly choosing a different saved location may begin a new session. Streaming results must identify an index still in progress; incomplete results must not be presented as a complete folder inventory.

| # | Feature | Acceptance requirement |
| --- | --- | --- |
| 1 | Compound, quoted, and negative queries | Combine filename terms, keep a quoted phrase together, and exclude a negative term. A nested match retains its complete ancestry; an invalid query reports a useful error. |
| 2 | Kind and extension filters | Filter files/folders and file extensions within the active root. Combining these filters with text terms must preserve both conditions. |
| 3 | Size filters | Apply explicit byte-size conditions to file metadata; zero-length files and comparison boundaries behave consistently. Folder size must not be inferred from directory-entry bytes. |
| 4 | Modified-date filters | Apply explicit date conditions consistently, including missing modification metadata and boundary dates. |
| 5 | Path filters | Match paths relative to the active root, without searching another volume or resolving a similarly named sibling root. |
| 6 | Sort order | Offer deterministic name, size, and modification ordering. Equal values have stable tie-breakers, and changing order cannot replace the session root. |
| 7 | Folder statistics | Show indexed file/folder counts and known logical file bytes, identifying partial indexing and unavailable metadata. |
| 8 | Largest files | Rank actual indexed files by logical size, with deterministic ties and a bounded list. Selecting a result refers to that real file. |
| 9 | Recent files | Rank actual indexed files by modification time, excluding invented dates and keeping the list bounded. |
| 10 | Duplicate-name groups | Group matching item names in different indexed branches, including folders, clearly distinguishing name duplication from equal file contents. |
| 11 | Favorites | Add/remove real folder locations, persist them locally, and handle a moved or missing favorite without opening a guessed location. |
| 12 | Recent locations | Record real visited locations, deduplicate and bound the history, and preserve it across a restart. |
| 13 | Saved searches | Persist reusable named queries and apply them to the current active root. Applying a saved filter must not silently open another folder or change the session root. |
| 14 | Keyboard tree navigation | Navigate/select visible cards with the keyboard while preserving ancestry. Text editing must retain ordinary arrow-key behavior. |
| 15 | Breadcrumbs | Navigate back through the active root's explored ancestry and remove deeper columns, without silently changing the root. |
| 16 | Next/previous search matches | Cycle through actual result matches in a deterministic order, excluding ancestry-only context cards and handling zero matches safely. |
| 17 | Pin HUD | Pin/unpin the current session with a visible state. Explicit Escape/dismissal must remain available; pinning must not resurrect stale asynchronous content. |
| 18 | Quick hidden-items toggle | Change hidden-item visibility and refresh both browsing and search consistently, respecting exclusions and the current root. |
| 19 | Reindex | Explicitly rebuild the current root's index. Cancel/supersede earlier work so an older index cannot overwrite a newer session. |
| 20 | CSV manifest | Export a real index snapshot with escaped CSV cells and a clear indication of a partial index. Export must not enumerate unrelated files or overwrite a destination without the native save flow. |
| 21 | Rename | Rename the explicitly chosen real item, reject unsafe names/collisions, refresh affected cards/indexes, and report failure without claiming success. |
| 22 | Duplicate | Duplicate the explicitly chosen real item to a collision-free sibling destination, preserve the original, and refresh the session. |
| 23 | New folder | Create a real folder in the chosen valid parent, reject unsafe names, choose a numbered sibling when a name already exists, and update browsing/indexing after success. |
| 24 | Copy relative path | Copy a path relative to the current root only for its descendants; never fabricate a relative path for an unrelated item. |
| 25 | Copy file URL | Copy the actual file URL with correct encoding for spaces, quotes, and Unicode. |
| 26 | Share | Present the native sharing interface for the chosen real file; cancellation preserves the file and session. |
| 27 | Open Terminal | Open the native Terminal at the intended real directory, passing paths without shell interpolation. Spaces and shell metacharacters cannot execute commands. |
| 28 | SHA-256 | Calculate the actual regular file's SHA-256 with bounded memory and asynchronous execution. Cancellation or another selection cannot publish a stale checksum. |
| 29 | Finder tags | Read/update native Finder tags on the chosen real item, preserving contents and displaying write failures. |
| 30 | Hover diagnostics | Show actionable permission/observation state from the actual tracker, including why activation is blocked. Diagnostics must not claim that an active process proves a verified Finder hit. |

## Preserved runtime behavior

With default settings, hover a Finder folder for three seconds, an inner folder card for approximately 300 ms, and a file for approximately 600 ms. Leaving or blocking the pending hover cancels activation. In search, first Escape restores normal browsing and second Escape dismisses the HUD; outside search Escape dismisses it directly.

Double-clicking a file in a HUD or tree opens its registered default application. Double-clicking a folder opens a **new Finder window** at that folder. Successful opening dismisses the HUD and preserves the chosen application's focus, including when a session was pinned. Automation denial must report a useful error.

Filesystem and session tests use temporary real fixtures; pure core tests can construct index-record values without accessing the filesystem. Tests do not add a product demo mode, simulate Finder, or substitute source inspection for interactive macOS verification.

## Query grammar and tool entry points

Open filtering with **⌘F**. Terms combine with AND; quote a phrase and prefix a term or filter with `-` to exclude it. Examples include `"annual report" -draft ext:pdf`, `kind:image size:>10MB`, and `ext:swift,json path:Sources`. Kind classification is based on the file extension rather than inspection of its contents. Sizes accept explicit decimal/binary units and comparisons or inclusive ranges, such as `size:1MiB..10MiB`.

Dates use UTC calendar days. `modified:2026-10-01` includes that full day; `before:2026-10-01` excludes it; `after:2026-10-01` starts on the following day. `modified:7d` is a rolling seven-day interval. Missing size/date metadata does not satisfy a positive condition. Unsupported filter names and malformed values report errors instead of silently dropping the condition.

The native **Workspace**, **Insights**, and **Tree tools** surfaces expose saved locations/filters, root summaries, ranking, sort order, visibility, pinning, reindexing, and export. Arrow keys navigate the tree while a text editor keeps ordinary cursor movement. **⌘G / ⇧⌘G** move through search matches, **⇧⌘P** toggles pinning, and **⌘R** refreshes when a text editor is not active. File actions are available from the native card context menu and the File HUD action menu.
