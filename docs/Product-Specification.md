Build a premium native macOS app called **Hoover**.

TAGLINE:
**“Hover deeper. See everything.”**

Hoover is a Finder-enhancement utility with TWO distinct hover experiences:

1. **FOLDER HOVER → Folder X-Ray**
   Hover over a folder in Finder for 3 seconds to open a spatial, recursively expandable folder tree.

2. **INDIVIDUAL FILE HOVER → Rich File HUD**
   Hover over an individual file to instantly display rich metadata and previews based directly on FinderHover.

For individual file hover behavior, features and implementation inspiration, include and study this project exactly:

[https://github.com/KoukeNeko/FinderHover?utm_source=chatgpt.com](https://github.com/KoukeNeko/FinderHover?utm_source=chatgpt.com)

If any FinderHover source code is reused rather than merely studied/reimplemented, comply with its MIT license and preserve required attribution/license notices.

Hoover must NOT include a Demo Mode.

====================================================
1. PRODUCT PRINCIPLE
====================================================

Hoover should make Finder feel like it has an intelligent spatial layer sitting directly above it.

Folders and files behave differently:

FOLDER:
Hover 3 seconds
→ X-Ray entire subtree spatially
→ hover folders recursively
→ horizontally expand through levels
→ search/filter whole subtree
→ manipulate files/folders

FILE:
Hover
→ lightweight rich metadata HUD
→ immediate preview
→ no folder-tree interface
→ automatically disappears when no longer relevant

Do not mix these two modes visually or behaviorally.

====================================================
2. FOLDER X-RAY ACTIVATION
====================================================

When the pointer remains over a FOLDER in Finder for 3 continuous seconds:

- activate Folder X-Ray automatically
- no keyboard modifier is required
- no click is required
- the hovered Finder folder becomes the ROOT of the X-Ray session
- project its contents spatially to the right side of Finder
- Finder itself remains visible underneath/behind the overlay

Do NOT require:
Option
Command
Space
click
double-click
context menu

The core interaction is simply:

HOVER FOLDER FOR 3 SECONDS.

====================================================
3. HOVER TIMER BEHAVIOR
====================================================

Default folder delay:
3.0 seconds

Make configurable in Settings.

Suggested range:
1–5 seconds.

During the activation period:

- tolerate tiny natural pointer movement
- cancel immediately if the pointer clearly leaves the folder
- do not trigger while the user is dragging something
- do not trigger while Finder is displaying a context menu
- do not trigger while renaming a file/folder
- avoid accidentally activating while the pointer merely passes over a folder

Optionally show a very subtle progress ring near the hovered folder.

The countdown visualization must be configurable/off by default if distracting.

====================================================
4. LEVEL 1
====================================================

Once activated:

The originally hovered Finder folder is ROOT.

Immediately enumerate its direct contents.

These become:

LEVEL 1

Example:

EdgeDock-source/

LEVEL 1
├── docs/
├── EdgeDock/
├── EdgeDock.xcodeproj
├── README.md
└── scripts/

Show them as vertically stacked floating cards.

The visual relationship between the actual Finder folder and Level 1 should be represented by a glowing curved connector.

====================================================
5. RECURSIVE HOVER EXPANSION
====================================================

Hovering any FOLDER inside Level 1 should reveal that folder's contents as Level 2.

Hovering a folder in Level 2 reveals Level 3.

Continue recursively:

ROOT
→ L1
→ L2
→ L3
→ L4
→ ...

Example:

EdgeDock-source
        │
        ▼
     EdgeDock
        │
        ▼
      Core
        │
        ▼
DockController.swift

The system should support arbitrary reasonable folder depth.

Do not impose an artificial L4 limit.

====================================================
6. LEVEL ACTIVATION SHOULD BE FAST
====================================================

The initial Finder root requires the deliberate 3-second activation.

Once X-Ray is already open, deeper levels should NOT each require another 3-second wait.

Inside X-Ray use a much shorter dwell delay.

Recommended:

250–400 ms

Behavior:

hover folder card
→ subtle focus
→ short delay
→ next level expands

Make this delay configurable.

====================================================
7. HORIZONTAL SPATIAL NAVIGATION
====================================================

Levels expand horizontally.

Example:

Finder     L1           L2            L3             L4

Folder → EdgeDock → Core → Services → Network.swift

Each level occupies its own vertical column.

The entire X-Ray canvas must support:

- horizontal trackpad scrolling
- inertial scrolling
- Shift + mouse wheel
- automatic scroll-to-reveal for newly opened levels
- fluid spring animation
- hundreds of pixels of safe space around columns
- no clipping against screen edges

When reaching the physical right edge of the display:
automatically shift/scroll the X-Ray canvas left enough to expose the new level.

====================================================
8. LEVEL HEADERS
====================================================

Each column receives a subtle technical header.

Example:

● LEVEL 1 · DIRECT TREE

● LEVEL 2 · EDGEDOCK / CORE SOURCE

● LEVEL 3 · CORE

Use small uppercase typography with increased tracking.

Headers should use the selected accent color but remain understated.

====================================================
9. ACTIVE PATH
====================================================

Always visually communicate the currently explored path.

Example:

EdgeDock-source
   ↓
EdgeDock
   ↓
Core
   ↓
DockController.swift

Active nodes:
highest opacity
stronger outline
accent glow

Ancestors:
high opacity
subtle connector emphasis

Sibling nodes:
medium opacity

Unrelated nodes:
lower visual emphasis

Do not make users lose orientation.

====================================================
10. CONNECTOR SYSTEM
====================================================

Use elegant curved Bezier/spline connectors.

Root Finder folder:
bright connector

Active ancestry path:
accent connector

Inactive branches:
thin translucent connector

Search result paths:
brighter animated connector

Connector animation should be restrained.

Possible effect:
a faint traveling light pulse when a deeper level opens.

====================================================
11. FOLDER/FILE CARDS INSIDE X-RAY
====================================================

Each node appears as a compact premium card.

Show:

ICON
NAME
TYPE/EXTENSION
OPTIONAL METADATA
TRASH/BIN ICON

Examples:

📁 docs
4 markdown guides · 240 KB                    🗑

📁 EdgeDock
8 Swift files · 1 Asset Catalog               🗑

SW DockController.swift
42 KB · Swift                                  🗑

README.md
Markdown · 7 KB                                🗑

Cards should not all be unnecessarily large.

Use adaptive card heights based on useful information.

====================================================
12. FILE PREVIEWS INSIDE THE TREE
====================================================

When useful, a selected/hovered file can display a richer preview card.

Examples:

CODE
- syntax-highlighted snippet
- language
- line count

IMAGE
- thumbnail
- dimensions
- size

PDF
- first-page preview
- page count

AUDIO
- title
- duration
- codec

VIDEO
- thumbnail
- duration
- resolution

MARKDOWN
- rendered title / first section

Keep previews lightweight and lazy-loaded.

====================================================
13. MOVE TO BIN BUTTON
====================================================

EVERY file and folder node visible in X-Ray must include a bin/trash icon.

Clicking the bin icon means:

MOVE TO BIN / TRASH

Never permanently delete by default.

Before moving:

show compact confirmation:

Move “DockController.swift” to Bin?

[ Cancel ] [ Move to Bin ]

For folders:

Move “Core” and all of its contents to Bin?

[ Cancel ] [ Move to Bin ]

After confirmation:

- use proper native macOS Trash behavior
- animate node collapsing/dissolving
- update parent folder metadata
- update level contents
- update search index
- collapse deeper columns if their ancestor was moved to Bin

If operation fails:
show clear non-destructive error state.

====================================================
14. BIN ICON INTERACTION
====================================================

The trash icon must:

- remain visible but visually subtle
- become stronger on card hover
- have a tooltip: “Move to Bin”
- never trigger by hovering
- only activate on explicit click
- use native confirmation unless user disables confirmation in Settings

Setting:

Confirm before moving to Bin
Default: ON

====================================================
15. CMD+F SEARCH MODE
====================================================

While Folder X-Ray is active:

Press:

⌘F

to enter TREE FILTER mode.

Also provide a small clickable Search icon/button so the user can invoke it without the keyboard.

Search applies ONLY to the tree beneath the ORIGINAL ROOT folder.

Absolutely do NOT search:
- entire Mac
- sibling Finder folders
- parent directories
- unrelated locations
- Spotlight globally

SEARCH SCOPE =
ROOT FOLDER SUBTREE ONLY.

====================================================
16. SEARCH BAR
====================================================

Search should appear as a floating bar at the top of the X-Ray canvas.

Example:

┌────────────────────────────────────────────────────────┐
│ 🔍 EdgeDock-source/   DockController        1 match × │
└────────────────────────────────────────────────────────┘

Show:
root folder context
query
match count
clear button

Focus the field immediately after ⌘F.

====================================================
17. SEARCHABLE STRINGS
====================================================

All of the following must work:

%folder name%
%filename%
%filename.extension%

Examples:

docs

EdgeDock

DockController

DockController.swift

swift

README

README.md

xcassets

Assets.xcassets

package.json

Users should not have to type wildcards.

`DockController`
should automatically match
`DockController.swift`.

`swift`
should match relevant `.swift` files.

====================================================
18. SEARCH RANKING
====================================================

For each keystroke, prioritize:

1. exact full name
2. exact basename
3. prefix match
4. substring match
5. extension match
6. optional lightweight fuzzy match

Never allow expensive fuzzy logic to make the UI feel slow.

Search is primarily a live filter rather than a traditional result list.

====================================================
19. SEARCH MUST UPDATE WHILE TYPING
====================================================

Filtering should occur continuously.

No Enter key required.

Example:

D
→ partial matching branches

Do
→ fewer branches

Dock
→ matching paths narrow

DockController
→ only matching ancestry remains

Target perceived response:
instant.

Do not wait for the user to finish typing.

====================================================
20. TREE DISSOLVE SEARCH BEHAVIOR
====================================================

This is a critical Hoover interaction.

Suppose tree contains:

EdgeDock-source
├── docs
├── EdgeDock
│   ├── App
│   ├── Core
│   │   ├── DockController.swift
│   │   ├── FileMonitor.swift
│   │   └── Settings.swift
│   └── Views
├── scripts
└── README.md

User searches:

DockController

The X-Ray should transform into:

EdgeDock-source
      │
      ▼
   EdgeDock
      │
      ▼
     Core
      │
      ▼
DockController.swift

Everything unnecessary should visually dissolve away.

DO NOT simply display a flat search result.

The user must see the WHOLE PATH leading to the matching file/folder.

====================================================
21. MULTIPLE SEARCH MATCHES
====================================================

If multiple matching files exist:

show all required branches.

Example:

ROOT
 ├── App
 │    └── Config.swift
 │
 └── Tests
      └── ConfigTests.swift

Search should preserve the minimum tree needed to understand every result.

If results span different branches, display those branches simultaneously.

====================================================
22. SEARCH ANIMATIONS
====================================================

When typing:

nonmatching nodes:
opacity 1
→ 0.45
→ 0
→ slight shrink
→ remove

matching nodes:
remain stable

ancestor nodes:
stay visible

matching text:
accent highlight

connectors:
recompute smoothly

Do not aggressively rearrange everything on every keystroke.

Use stable layout transitions to avoid visual jitter.

====================================================
23. SEARCH PERFORMANCE
====================================================

Search must be designed for very fast incremental matching.

When Folder X-Ray activates:

- progressively index names underneath root folder
- build lowercase normalized names
- cache basename
- cache extension
- cache relative path
- perform indexing asynchronously
- prioritize currently visible/depth-near directories
- support cancellation if the root changes

Do not block UI while recursively indexing.

For enormous directory trees:
results can stream progressively.

Show subtle:

“Indexing deeper folders…”

only when necessary.

====================================================
24. SEARCH RESULT PATH OPENING
====================================================

When search finds something deep that had never been manually expanded:

automatically construct the required visible ancestry:

Root
→ Parent
→ Parent
→ Result

The user should not need to manually navigate levels first.

====================================================
25. ESCAPE BEHAVIOR
====================================================

EXACT behavior:

IF SEARCH IS ACTIVE:

First Esc
→ dismiss search/filter mode
→ restore normal X-Ray tree

Second Esc
→ dismiss whole X-Ray session

IF SEARCH IS NOT ACTIVE:

Esc
→ dismiss whole X-Ray session

This behavior is mandatory.

====================================================
26. INDIVIDUAL FILE HOVER MODE
====================================================

Folders use Folder X-Ray.

INDIVIDUAL FILES must use a completely different hover interface inspired directly by FinderHover.

Reference:

[https://github.com/KoukeNeko/FinderHover?utm_source=chatgpt.com](https://github.com/KoukeNeko/FinderHover?utm_source=chatgpt.com)

For individual files:

hover a file in Finder
→ wait for short configurable delay
→ show a floating rich metadata HUD near the file
→ automatically dismiss when pointer leaves or Finder context changes

Do NOT show Level 1 / Level 2 / folder tree UI for an ordinary file.

The file HUD should behave like an X-ray information layer.

====================================================
27. FILE HOVER DELAY
====================================================

Folder:
default 3 seconds

Individual file:
much faster

Use adjustable delay comparable to FinderHover:
0.1–2.0 seconds.

Recommended Hoover default:
0.6 seconds.

Separate settings:

Folder X-Ray Delay
3.0 sec

File Info Delay
0.6 sec

====================================================
28. FILE HUD — BASIC METADATA
====================================================

For a normal file show:

- filename
- icon / thumbnail
- file type
- extension
- file size
- creation date
- modification date
- Finder tags
- path
- iCloud state if relevant
- quarantine/download source where available
- symlink target where applicable

Keep essential information near the top.

====================================================
29. FILE HUD — QUICK LOOK
====================================================

Use native QuickLook thumbnail generation.

Support rich thumbnails for:

- images
- PDFs
- documents
- videos
- source files where appropriate

The HUD should appear quickly even if thumbnail generation takes longer.

Metadata first.
Thumbnail can fade in afterward.

====================================================
30. FILE HUD — PHOTOS
====================================================

For photos expose relevant deep metadata similar to FinderHover:

- dimensions
- camera model
- lens
- focal length
- ISO
- aperture
- shutter speed
- color profile
- HDR information
- IPTC/XMP metadata
- author/copyright where present
- keywords
- rating
- GPS data where present

Do NOT upload metadata anywhere.

====================================================
31. FILE HUD — VIDEO
====================================================

Show:

- resolution
- duration
- codec
- bitrate
- frame rate
- HDR format
- Dolby Vision / HDR10 / HLG when detectable
- audio tracks
- subtitle tracks
- chapter count where available

====================================================
32. FILE HUD — AUDIO
====================================================

Show:

- track title
- artist
- album
- genre
- duration
- bitrate
- sample rate
- channels
- codec
- embedded artwork where available

====================================================
33. FILE HUD — CODE
====================================================

For source code show:

- detected language
- file size
- line count
- encoding
- optional syntax-highlighted snippet
- Git status when relevant

Support common development languages extensively.

====================================================
34. FILE HUD — ARCHIVES
====================================================

For archive files such as:

zip
rar
7z
tar
tar.gz
iso

show contents WITHOUT extracting where technically possible.

Show:

- file count
- directory count
- compressed size
- uncompressed size
- compression ratio
- encryption/password protection state
- small preview of contained filenames

====================================================
35. FILE HUD — MARKDOWN
====================================================

For Markdown show:

- title
- frontmatter
- heading count
- links
- images
- code-block count
- basic document statistics
- short rendered preview

====================================================
36. FILE HUD — CONFIGURATION FILES
====================================================

For:

JSON
YAML
TOML
XML
plist

show:

- validity
- key count
- nesting depth
- top-level keys
- short syntax-highlighted preview

====================================================
37. FILE HUD — APP/BINARY INFORMATION
====================================================

For app bundles and executable binaries show where available:

- bundle ID
- version
- minimum macOS
- architectures
- arm64/x86_64/Universal
- code signing status
- entitlements summary
- SDK version
- executable type

Use safe read-only inspection.

====================================================
38. FILE HUD — SQLITE
====================================================

For SQLite databases show metadata such as:

- table count
- index count
- trigger count
- view count
- row estimates/counts where inexpensive
- schema version
- encoding
- database size

Do not modify the database.

====================================================
39. FILE HUD — DESIGN FILES
====================================================

Where parsers/native frameworks make it practical:

PSD:
layers
dimensions
color mode
bit depth

SVG:
viewBox
dimensions
element counts

Fonts:
family
style
glyph information

3D models:
mesh count
vertex count
face count
materials
animations
bounding box

====================================================
40. FILE NOTES
====================================================

Provide an optional notes section for individual files.

User can attach a short personal note to a file.

Prefer storing the note in a manner that can follow the file when safely supported, similar in spirit to FinderHover.

Do not alter file contents merely to store a note.

Provide a setting to disable notes completely.

====================================================
41. FILE HUD AUTO-HIDE
====================================================

Automatically hide file HUD when:

- pointer moves away
- user starts renaming
- user starts dragging
- Finder context menu appears
- Finder window disappears
- selected/hovered file changes
- another Hoover interaction supersedes it

Avoid stale floating windows.

====================================================
42. FILE HUD APPEARANCE
====================================================

Offer two information density choices:

HOOVER RICH
thumbnail + categories + deep metadata

HOOVER COMPACT
small tooltip-like panel with essential metadata

The application retains Hoover branding in both.

====================================================
43. FOLDER VS FILE DETECTION
====================================================

Reliable behavior is essential.

Pointer over folder:
→ schedule 3-second Folder X-Ray

Pointer over regular file:
→ schedule short File HUD

If pointer changes from file → folder:
cancel previous timer immediately.

If pointer changes from folder → file:
cancel Folder X-Ray countdown immediately.

Never display both interfaces for the same item simultaneously.

====================================================
44. SPECIAL FOLDER METADATA
====================================================

Folder X-Ray is the primary behavior for folders.

However, folders can also show small useful metadata INSIDE their X-Ray cards:

- child count
- total size when inexpensive/cached
- Git repository indicator
- package/project type
- last modified
- iCloud state

Do NOT replace Folder X-Ray with the individual-file HUD for folders.

====================================================
45. GIT-AWARE FOLDERS
====================================================

If a folder is a Git repository, its X-Ray card may show:

repository
branch
dirty/clean state
uncommitted count

Example:

EdgeDock
SOURCE ROOT

main*
8 Swift Files · 1 Asset Catalog

Click an optional Git detail control to reveal:

branch
remote
commit summary
changed files

Keep Git features read-only in Hoover v1.

====================================================
46. XCODE PROJECT AWARENESS
====================================================

For `.xcodeproj` / `.xcworkspace` items show:

project name
targets
build configurations
Swift version
deployment target

Where this can be extracted safely.

====================================================
47. OPACITY SYSTEM
====================================================

Carefully reproduce the visual hierarchy shown in the supplied mockups.

Suggested values — tune visually:

Active card:
92–100% visual prominence

Ancestor card:
80–95%

Sibling card:
60–80%

Inactive card:
30–55%

Search-dissolving card:
30%
→ 15%
→ 0%

Overlay background:
mostly transparent

Finder must remain recognizably visible.

Use blur selectively rather than placing a giant opaque rectangle over Finder.

====================================================
48. DARK / LIGHT MODES
====================================================

Support:

System
Light
Dark

Dark:
graphite/navy translucent cards
bright accent path
soft neon

Light:
white/frosted cards
thin shadows
more restrained glow
high text clarity

Both must feel equally intentional.

====================================================
49. ACCENT THEMES
====================================================

Support configurable accent colors.

Built-in presets:

Electric Cyan
Azure
Violet
Mint
Graphite
Sunset Orange
Rose

Accent color affects:

- active borders
- connector lines
- search highlight
- level dots
- focus indicators
- selected icons
- HUD accents

Do NOT recolor every surface.

====================================================
50. LIQUID GLASS
====================================================

Setting:

Enable Liquid Glass

DEFAULT:
OFF

When OFF:
use elegant standard macOS translucent/blur materials.

When ON:
use Apple-style refractive/translucent glass treatment where supported.

Use it for:

- cards
- search bar
- bottom HUD
- metadata popup
- settings panes

Do NOT sacrifice readability.

Automatically fall back gracefully on macOS versions where specific effects are unavailable.

====================================================
51. MENU BAR ONLY
====================================================

Hoover must NOT normally appear in the Dock.

Configure as menu-bar utility / accessory application.

Menu bar icon:
minimal Hoover glyph.

Click it to open:

Hoover
● Active

Pause Hoover

Folder X-Ray
Enabled

File Hover
Enabled

Settings…

About Hoover

Quit Hoover

Optional:
Launch at Login

====================================================
52. MENU BAR ACTIVE STATE
====================================================

Menu bar icon may subtly indicate:

Idle
active hover
X-Ray open
paused

Do not animate continuously in an annoying way.

====================================================
53. HOOVER APP ICON
====================================================

Design a premium app icon.

Concept:

A dimensional folder composed of 3–4 translucent nested layers.

The center contains a minimal branching/X-Ray glyph.

Visual metaphor:

folder
+
layers
+
depth
+
hover reveal

Avoid:
literal vacuum cleaner imagery.

App icon should remain recognizable at:

1024 px
128 px
32 px
16 px

====================================================
54. MENU BAR ICON
====================================================

Create a monochrome template icon suitable for macOS menu bar.

Suggested silhouette:

folder outline
+
two nested horizontal depth lines

or:

stylized H made from layered panels.

Must remain readable at approximately 16–18 pt.

====================================================
55. BRANDING
====================================================

NAME:
Hoover

PRIMARY TAGLINE:
Hover deeper. See everything.

Brand personality:

precise
fast
quiet
premium
technical
spatial
Mac-native

Avoid playful cartoon styling.

====================================================
56. CLICKING X-RAY ITEMS
====================================================

Single click file:
select/pin its rich preview.

Double click file:
open normally.

Single click folder:
pin branch / optionally expand immediately.

Double click folder:
open actual folder in Finder.

Space:
Quick Look currently highlighted file.

Return:
open/reveal selected item depending on context.

====================================================
57. CONTEXT ACTIONS
====================================================

Right-click an X-Ray node to offer native-style actions:

Open
Open With
Quick Look
Reveal in Finder
Copy
Copy Path
Copy Filename
Get Info
Move to Bin

Optional:
New Finder Window Here

Do not recreate every Finder command unnecessarily.

====================================================
58. DRAG SUPPORT
====================================================

Where technically robust:

Allow dragging a file/folder FROM Hoover's X-Ray tree into:

- Finder
- Desktop
- another app
- Mail
- Messages
- upload target

It should behave like dragging the original Finder item.

This is secondary to the core X-Ray behavior.

====================================================
59. ROOT SESSION BOUNDARY
====================================================

Once Folder X-Ray activates:

the originally hovered folder becomes the immutable search/session ROOT until:

- overlay is dismissed
- user deliberately activates another Finder folder for 3 seconds
- root no longer exists
- Finder context becomes invalid

Searching never escapes above this root.

====================================================
60. FOLDER CONTENT LIVE UPDATES
====================================================

If folder contents change while X-Ray is open:

- update visible level
- preserve selection where possible
- animate inserted node in
- animate removed node out
- avoid rebuilding the entire UI

Use filesystem observation where appropriate.

====================================================
61. EMPTY FOLDERS
====================================================

Hovering an empty folder inside X-Ray should display:

EMPTY FOLDER

as a small elegant state in the next level.

Do not show a blank mysterious column.

====================================================
62. PERMISSION FAILURES
====================================================

For unreadable locations show:

Permission Required

or:

Access unavailable

Do not repeatedly trigger system permission prompts.

Offer a clear action only when appropriate.

====================================================
63. SYMLINKS
====================================================

Show symlink status clearly.

Avoid accidentally creating recursive infinite traversal.

Detect:

- symbolic link loops
- aliases
- recursive paths

Provide configurable:
Follow symlinks
Default: OFF for recursive indexing.

====================================================
64. LARGE DIRECTORY SAFETY
====================================================

Hoover must remain responsive in folders containing:

10 files
1,000 files
100,000+ descendants

Use:

- lazy enumeration
- streaming indexes
- cancellation
- directory cache
- filesystem events
- batched updates
- background queues
- render virtualization

Never recursively load an enormous tree synchronously.

====================================================
65. SEARCH DATA STRUCTURE
====================================================

Create a per-root ephemeral search index optimized for live typing.

Suggested normalized fields:

nameOriginal
nameLowercase
basenameLowercase
extensionLowercase
relativePathLowercase
isDirectory
parentID
depth

Potential optimization:
prefix index / compact trie / token map

But keep memory usage sensible.

Destroy or age-out index when root session ends.

====================================================
66. SEARCH DEBOUNCE
====================================================

For lightweight matching:
update on every keypress.

Use only tiny debounce if necessary:
~15–40 ms.

Do not use a slow 200–500 ms search debounce.

The UI must feel instantaneous.

====================================================
67. APP ARCHITECTURE
====================================================

Native macOS only.

Preferred technologies:

Swift
SwiftUI
AppKit
Accessibility APIs
CoreGraphics
QuickLookThumbnailing
AVFoundation
PDFKit
ImageIO
UniformTypeIdentifiers
FileManager
FSEvents / filesystem observation where appropriate
Combine or Observation
SQLite only if persistence/index cache becomes necessary

No Electron.
No Tauri.
No browser wrapper.

====================================================
68. ACCESSIBILITY-BASED FINDER TRACKING
====================================================

Study FinderHover's approach to Finder item detection.

The reference project states that it uses macOS Accessibility APIs and system accessibility event information rather than slow AppleScript polling.

Hoover should follow the same architectural principle where practical:

- identify Finder under cursor efficiently
- keep UI responsive
- avoid constant expensive AppleScript queries
- keep work off main thread
- request only required permissions

====================================================
69. LOCAL-FIRST PRIVACY
====================================================

Hoover must operate locally.

Metadata extraction:
local.

Folder search:
local.

Thumbnail generation:
local.

File inspection:
local.

No analytics upload by default.
No file contents sent to remote services.
No cloud AI required.

Clearly explain Accessibility permission during onboarding.

====================================================
70. SETTINGS — GENERAL
====================================================

General:

Hoover Enabled
ON

Launch at Login
optional

Folder X-Ray
ON

Folder Hover Delay
3.0 sec

Individual File HUD
ON

File Hover Delay
0.6 sec

Click Outside to Dismiss
configurable

Show Folder Hover Countdown
configurable

====================================================
71. SETTINGS — APPEARANCE
====================================================

Appearance:

Theme
System / Light / Dark

Accent
Electric Cyan / Azure / Violet / Mint / Graphite / Orange / Rose

Liquid Glass
OFF by default

Window Opacity
70–100%

Glow Intensity
Low / Medium / High

Text Size
Compact / Default / Large

Card Density
Compact / Comfortable

====================================================
72. SETTINGS — FOLDER X-RAY
====================================================

Folder X-Ray:

Root Hover Delay

Inner Folder Hover Delay

Auto-scroll to New Level

Show Connector Lines

Show File Preview

Show Folder Metadata

Show Git Details

Show Trash Icons

Confirm Move to Bin

Follow Symbolic Links
Default OFF

====================================================
73. SETTINGS — FILE HUD
====================================================

File HUD:

Enable File Hover

Hover Delay

Rich / Compact Layout

Show Thumbnail

Show Basic Metadata

Show Deep Metadata

Show Developer Metadata

Show Media Metadata

Show Download Source

Show Finder Tags

Show Notes

Opacity

Field Ordering

Allow user to reorder metadata categories.

====================================================
74. SETTINGS — SEARCH
====================================================

Search:

Enable fuzzy fallback

Highlight matched characters

Index hidden files

Include package contents

Maximum background indexing depth
Auto recommended

Search hidden files:
configurable

By default respect normal Finder hidden-file visibility where sensible.

====================================================
75. SETTINGS — EXCLUSIONS
====================================================

Allow exclusion of:

specific paths
volumes
external disks
network shares

Example:

Do not X-Ray:
~/Library
/System
/private

Do not enforce these exact exclusions automatically if unnecessary; offer safe sensible defaults.

====================================================
76. NO DEMO MODE
====================================================

IMPORTANT:

Do NOT implement a Demo Mode.

Do NOT add:
- fake folder trees
- simulated Finder events
- fake files
- sample repositories presented as product functionality
- demo toggle
- “Open Demo Mode” menu item

All actual app behavior should be built around real Finder items.

For development/testing, unit tests and internal debug fixtures are fine, but they must not ship as a user-facing Demo Mode.

====================================================
77. FIRST IMPLEMENTATION PRIORITY
====================================================

Implement in this order:

PHASE 1 — Finder detection
- Accessibility permission
- reliable item-under-pointer detection
- distinguish file vs folder
- menu bar app
- no Dock icon

PHASE 2 — Folder X-Ray
- 3 sec hover
- Level 1
- recursive level hover
- connectors
- horizontal scrolling
- Esc behavior

PHASE 3 — Search
- Cmd+F
- subtree indexing
- filename/folder/extension matching
- dissolve filtering
- auto-construct ancestry to deep result
- multiple result paths

PHASE 4 — Individual file HUD
- FinderHover-inspired metadata popup
- QuickLook thumbnails
- deep metadata
- rich file-type extractors

PHASE 5 — File operations
- bin icons
- Move to Bin
- contextual actions
- Quick Look
- open/reveal
- live filesystem updates

PHASE 6 — Polish
- Light/Dark
- accents
- Liquid Glass option
- animation tuning
- performance optimization

====================================================
78. ABSOLUTELY CRITICAL UX TESTS
====================================================

TEST A

User hovers:

Downloads/EdgeDock-source

for 3 sec.

Expected:
Hoover X-Ray appears.

No key needed.

----------------------------------------------------

TEST B

Inside X-Ray user hovers:

EdgeDock/

Expected:
Level 2 immediately appears after short inner hover delay.

----------------------------------------------------

TEST C

Then hover:

Core/

Expected:
Level 3 appears.

Horizontal canvas automatically scrolls if needed.

----------------------------------------------------

TEST D

Press:

⌘F

Type:

DockController

Expected:

Every irrelevant Level 1+ branch dissolves.

Visible result:

EdgeDock-source
→ EdgeDock
→ Core
→ DockController.swift

----------------------------------------------------

TEST E

Press Esc.

Expected:
search disappears.
normal X-Ray returns.

Press Esc again.

Expected:
whole X-Ray disappears.

----------------------------------------------------

TEST F

Hover:

statement.pdf

Expected:
NO folder X-Ray.

Instead display Hoover File HUD containing PDF thumbnail and relevant metadata.

----------------------------------------------------

TEST G

Hover:

photo.CR3 / JPG / HEIC

Expected:
File HUD with photography metadata.

----------------------------------------------------

TEST H

Hover:

archive.zip

Expected:
File HUD includes archive information and contents preview without requiring extraction.

----------------------------------------------------

TEST I

Click bin icon next to:

README.md

Expected:
confirmation.

Confirm.

Expected:
macOS moves README.md to Bin/Trash and Hoover updates the tree.

====================================================
79. VISUAL QUALITY BAR
====================================================

The supplied mockups represent the desired direction.

Preserve:

- actual Finder visible in background
- luminous connector originating at root item
- dark floating hierarchy cards
- cyan/electric accent
- spatial level labels
- increasingly deep rightward columns
- focused opacity hierarchy
- bottom-right control pill
- floating search field
- search path emphasis
- dissolved unrelated branches
- thin high-quality typography
- polished blur

But refine everything to look like a final macOS product rather than a concept render.

====================================================
80. FINAL PRODUCT EXPERIENCE
====================================================

FOLDER:

User points at a Finder folder.

3 seconds later the folder appears to “open spatially” without actually opening Finder windows.

The entire internal hierarchy becomes explorable through hover.

Hover folder:
next level.

Hover another folder:
next level.

Trackpad:
move through depth.

⌘F:
search only inside that root.

Type filename:
unrelated branches dissolve.

Esc:
clear search.

Esc:
close Hoover.

FILE:

User points at a file.

A fast lightweight metadata HUD appears.

PDF:
preview + metadata.

Photo:
EXIF.

Video:
codec/HDR/frame rate.

Archive:
contents/compression/encryption.

Source code:
language/line count/encoding.

Executable:
architecture/signing information.

Then pointer leaves.

HUD quietly disappears.

That combination is Hoover:

**Folders become spatially transparent.
Files become informationally transparent.**

Build it so that once someone uses Hoover for a few days, opening multiple Finder windows merely to inspect files and folder structures feels unnecessarily slow.