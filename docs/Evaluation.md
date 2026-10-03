# Hoover evaluation record

Final validation of **Hoover 1.0.1, build 2** ran from `2026-10-03T20:34:50Z` to `2026-10-03T20:37:17Z` (UTC). The current cloud host is Debian 13 x86_64. The native GitHub workflow has built and tested real macOS applications on both macOS 14 and 15; interactive Finder checks still require a Mac desktop.

## Toolchain integrity

Swift 6.1.3 for Ubuntu 24.04 was downloaded from the official `download.swift.org` release location and verified with its detached GPG signature **before** extraction or execution. Signing keys came from the official `swiftlang/swift-org-website` Git checkout because the runtime network policy blocked `swift.org/keys/all-keys.asc`. The verifying Swift 6 release fingerprint was `52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F`. The key is expired at evaluation time; the valid signature was made September 5, 2025, before expiry. TLS, checksums, and signature verification were not disabled.

Swift and module caches use writable locations under `/workspace`; no HOME override or credential copying is used.

## Executed checks

| Check | Result | Scope |
| --- | --- | --- |
| Portable core and bounded streaming tests | PASS, **26 XCTest cases** in final Linux CI and both native suites | Hover timers/suppression, Escape, filesystem enumeration, root-confined search, ranking, exclusions, hidden/packages, deep nesting, symlink loops/escapes, cancellation, slow-consumer delivery of 2,001 records, Unicode equivalence, and root context excluded from descendant matches. |
| Native Swift syntax and semantic/API build | PASS on macOS 14 and 15 | Real Apple SDK compilation and linking succeeded in the native workflow; Linux syntax parsing also passed. |
| Bundle metadata and shell syntax | PASS | `LSUIElement`, executable name, minimum macOS, valid plist data, `bash -n`, icon-script Swift parsing. |
| Native metadata/settings/session/rendering/action tests | PASS, **40 native + 26 core = 66 tests**, zero failures and zero skips, on each platform | Test-only real file fixtures for ZIP, notes, strict JSON/XML, subprocesses, text, images, PDF, settings, session restoration, verified background hover/dwell reset, unique Finder names, native view snapshots, actual recoverable Trash, and clipboard operations. |
| Native release app build and signature verification | PASS on macOS 14 and 15 | Real universal arm64 + x86_64 Mach-O, Info.plist, `.icns`, resources in standard Contents/Resources, ad-hoc signing, strict signature verification, and downloadable ZIP artifacts. |
| Packaged application launch smoke | PASS on both macOS hosts | Compiled app reported `applicationDidFinishLaunching` and remained running before only the test-launched process was stopped. This does not establish interactive Finder correctness. |
| Native UI snapshot generation | PASS, four PNGs on each macOS host | Dark hierarchy, light hierarchy, filtered ancestry, and source HUD rendered. The cloud runtime blocks the external artifact blob host, so human visual inspection of downloaded snapshots remains pending. |
| Interactive tests A–J | PENDING interactive Mac | Accessibility detection, actual Finder/default app opening, window placement, keyboard interception, Trash, Quick Look, and display behavior need a macOS desktop. |

Final proof: [successful workflow run 37152048440](https://github.com/sknitd/hoover/actions/runs/37152048440), source commit [`1f28bfb3f2bb2529b868d2e96b79ca8b33326005`](https://github.com/sknitd/hoover/commit/1f28bfb3f2bb2529b868d2e96b79ca8b33326005). Every job succeeded. macOS 14 executed 66 tests in 5.984 seconds; macOS 15 executed 66 tests in 6.968 seconds. Both reports show zero failures and zero skips, an `x86_64 arm64` executable, successful strict code-signature verification, and successful packaged application launch smoke.

| Artifact | Download |
| --- | --- |
| Universal app built on macOS 14 | [Hoover-macos-14](https://github.com/sknitd/hoover/actions/runs/37152048440/artifacts/11283914682) |
| Universal app built on macOS 15 | [Hoover-macos-15](https://github.com/sknitd/hoover/actions/runs/37152048440/artifacts/11284586004) |
| Four native UI snapshots on macOS 14 | [Hoover-UI-macos-14](https://github.com/sknitd/hoover/actions/runs/37152048440/artifacts/11284905123) |
| Four native UI snapshots on macOS 15 | [Hoover-UI-macos-15](https://github.com/sknitd/hoover/actions/runs/37152048440/artifacts/11284586007) |

GitHub reports these SHA-256 digests for the downloadable app artifact archives:

- macOS 14: `6a29fe9ca58d3aa1359b84800a70b6cc157b33fa8d309ab414db149186dc7fb6`
- macOS 15: `0de37970c240cf891ebbee4899d0ecb3fe42f97765c4a3e17989a74b7ef4f2fa`

These identify the GitHub artifact archives, rather than an individual executable or inner app ZIP. The cloud runtime could inspect GitHub's authenticated check annotations and artifact metadata, but could not download from the external artifact blob host. Downloads and visual inspection therefore remain available through the GitHub links above.

The final source includes the Finder hover/name repairs, structured thumbnail cancellation, guarded Finder focus restoration, and constant-time header/progress updates described below. Independent source review, Swift parsing, whitespace checks, and the completed native builds cover that source revision. No final source change remains awaiting CI.

## Runtime report and hover repair

The user reported Hoover as **Active** in Finder **List view**, with no overlay. This failure was not independently reproduced in the Linux cloud session, which cannot observe or control the user's Mac desktop. The corrected app's runtime result on that Mac remains pending a **1.0.1 retry**.

Source review identified a concrete activation gap: item hit testing previously required foreground Finder, preventing no-click hovering over exposed Finder items while another app remained active. Version 1.0.1 accepts a system Accessibility hit only when its owning process is Finder. It also resumes hit testing after closing Hoover onboarding when the accessory app remains foreground without a key/modal window; active Hoover key/modal windows still suppress new Finder hits, including a window opened during an in-flight probe. These source repairs do not establish that this gate was the sole cause of the user's failure.

Three native coordinator regressions use real temporary folders and an injected monotonic clock. They verify that a verified background Finder observation opens the correct real folder after the full three-second dwell, an unverified background observation never opens it, and a blocked interaction requires a fresh full dwell. Six further real-filesystem tests verify hidden-extension collision rejection, unique hidden-label resolution, incomplete-scan rejection, exact filenames, ordinary folder labels, and conflicting label attributes. All nine additions passed on both macOS hosts. Actual Accessibility item resolution, the closing-onboarding interaction, and the updated app's behavior on the user's Mac remain interactive checks.

## Large-tree evaluation and repair loop

An optimized standalone executable compiled the real `HooverCore` sources and created **100,000 actual empty files** in 100 directories. All fixtures were removed after testing. The first measurement indexed all 100,101 records in 4.607 seconds across 784 batches; first batch arrived in 1.3 ms. A precise filename produced one match with exactly its three required ancestry IDs; the extension query matched all 100,000 files.

The first name-query timings were 0.59–0.66 seconds, and the broad extension query took 2.97 seconds. Those timings did not satisfy the intended immediate live response at that size. Evaluation requested cached node identities, cheaper stable ranking comparisons, fewer repeated ancestry walks, and avoiding unnecessary map creation. The implementation now also uses NFC-normalized UTF-8 matching and builds only directory ancestry maps. Column preparation and sorting occur off the main actor.

An independent final optimized rerun indexed all 100,101 records in **4.533 seconds**, with the first batch at **2.3 ms**. Precise filename filtering took **18 ms**; no-match and folder queries each took **17 ms**; an extension query returning 100,000 matches took **142 ms**. Exact match counts and complete ancestry passed. These are Linux core timings; macOS interactive rendering and peak-memory measurements remain pending. Reproduce the evaluation with `bash scripts/stress-core.sh`.

## Findings repaired during review

- Indexing follows an explicitly selected symlink root correctly while preventing descendant links escaping the canonical root or looping.
- Exclusions prune recursively, with path-component boundaries and volume controls, rather than only hiding the selected root.
- Stream buffering is bounded and lossless when the consumer is slower than filesystem enumeration.
- File actions pass paths as process arguments and use bounded subprocess execution. New Finder windows/default file apps dismiss the HUD after successful opening; failures report errors.
- Package items open with their registered application. Trash uses the system's recoverable operation with confirmation on by default.
- Inner folder dwell now cancels on hover exit; asynchronous loading no longer presents a misleading empty-folder state; search without matches has a visible state.
- Tree-column identity includes level, preventing duplicate identities when multiple search branches share a contextual parent.
- Icon caches have a bounded entry count. Native glass has a supported-version path and fallback.
- Strict bounded JSON validation rejects extensions accepted by Darwin's permissive Foundation parser; metadata labels have unique stable identities even when localized fields repeat.
- Preview thumbnails use a structured child task, check cancellation before mutating Quick Look state, and independently invalidate stale thumbnail generations so older file previews cannot replace or cancel a newer request.
- Final overlay dismissal restores Finder only while Hoover owns the foreground key panel, without a modal dialog or another visible key window. File opening, Open With, external activation/clicks, lifecycle shutdown, and settings/about paths explicitly avoid restoring Finder over the chosen app. Interactive focus behavior is included in test E and remains a desktop check.
- Unchanged hover progress no longer publishes repeated UI updates. Search column headers use the prepared parent context in constant time while preserving a distinct label for matching branches.
- Verified Finder pointer ownership permits no-click background hovering and resumes after onboarding closes without an active Hoover key/modal window. Unverified observations cannot activate a session.
- Name-only Finder resolution checks all display labels before accepting a unique sibling. An exact extensionless filename cannot override a colliding hidden-extension label, and incomplete or conflicting label results cannot select a file.

## Known inspection limits

Finder name-only fallback requires a complete scan of at most **2,000 direct siblings**, including hidden siblings. Truncated or failed scans suppress that fallback rather than claiming uniqueness; trusted per-item Accessibility URL/path attributes remain usable in larger directories. Some column-view Accessibility configurations omit both item URLs and reliable column-local directory context, so the conservative resolver may omit previews there. These limits and the reported no-overlay failure require actual Finder checks.

Metadata is local and bounded. Unsupported or partial formats are labeled honestly: 7z/RAR native content parsing is unavailable; ISO/disk-image names are not mounted to list files; general 3D meshes are not deeply parsed except bounded OBJ statistics; YAML/TOML are observed rather than fully validated. RAW, media, artwork, and Quick Look support depends on the macOS frameworks and installed system support. Files above the deep-inspection size limit still receive basic metadata. These limitations remain visible in the HUD.

The macOS semantic builds, automatic tests, signing checks, and launch smoke have passed. [Test-Plan.md](Test-Plan.md)'s interactive checks remain necessary before claiming Finder behavior and visual quality are fully verified. Native screenshots can support visual inspection but do not establish actual Finder detection or file-action correctness.
