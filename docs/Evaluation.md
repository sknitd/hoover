# Hoover evaluation record

Evaluation date: 2026-10-04. The current cloud host is Debian 13 x86_64; native macOS testing is delegated to the macOS GitHub workflow and interactive Mac checks.

## Toolchain integrity

Swift 6.1.3 for Ubuntu 24.04 was downloaded from the official `download.swift.org` release location and verified with its detached GPG signature **before** extraction or execution. Signing keys came from the official `swiftlang/swift-org-website` Git checkout because the runtime network policy blocked `swift.org/keys/all-keys.asc`. The verifying Swift 6 release fingerprint was `52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F`. The key is expired at evaluation time; the valid signature was made September 5, 2025, before expiry. TLS, checksums, and signature verification were not disabled.

Swift and module caches use writable locations under `/workspace`; no HOME override or credential copying is used.

## Executed checks

| Check | Result | Scope |
| --- | --- | --- |
| Portable unit tests, initial independent run | PASS, 23 XCTest cases | Hover timers/suppression, Escape, filesystem enumeration, root-confined search, ranking, exclusions, hidden/packages, deep nesting, symlink loops/escapes, cancellation. |
| Final optimized core and bounded streaming | Independent PASS, **25 XCTest cases** | Adds a slow-consumer regression with 2,001 records delivered once each and a Unicode byte-matching/canonical-equivalence regression. |
| Native Swift syntax | PASS in independent integrated recheck | Swift parser accepts native sources without loading Apple SDKs. Semantic/API validation requires macOS. |
| Bundle metadata and shell syntax | PASS | `LSUIElement`, executable name, minimum macOS, valid plist data, `bash -n`, icon-script Swift parsing. |
| Native metadata/settings/session/rendering tests | PENDING macOS, 23 tests authored | Test-only real file fixtures for ZIP, notes, subprocesses, text, images, PDF, settings, session restoration, and native view snapshots. |
| Native release app build and signature verification | PENDING macOS | Universal Mach-O, Info.plist, `.icns`, resource bundle, ad-hoc/selected identity signing, signature validation, archive. Linux does not produce a pretend `.app`. |
| Interactive tests A–J | PENDING interactive Mac | Accessibility detection, actual Finder/default app opening, window placement, keyboard interception, Trash, Quick Look, and display behavior need a macOS desktop. |

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

## Known inspection limits

Metadata is local and bounded. Unsupported or partial formats are labeled honestly: 7z/RAR native content parsing is unavailable; ISO/disk-image names are not mounted to list files; general 3D meshes are not deeply parsed except bounded OBJ statistics; YAML/TOML are observed rather than fully validated. RAW, media, artwork, and Quick Look support depends on the macOS frameworks and installed system support. Files above the deep-inspection size limit still receive basic metadata. These limitations remain visible in the HUD.

The release decision requires the macOS semantic build and [Test-Plan.md](Test-Plan.md)'s interactive checks. Native screenshots can support visual inspection but do not establish actual Finder detection or file-action correctness.
