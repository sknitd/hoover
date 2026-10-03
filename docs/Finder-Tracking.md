# Finder tracking

Hoover uses macOS Accessibility hit testing, with no AppleScript polling. FinderTracker reports the actual item under the pointer; it never falls back to Finder's selected files, common home-directory locations, or global search.

A 90 ms main-run-loop timer captures the pointer, active application, pressed buttons, and primary display transform. A single serial background probe resolves that position. No concurrent AX calls or queued polling backlog is created. Stop/restart and active-application changes invalidate old results, and a moving pointer must still overlap the returned item before the observation can be delivered.

The probe verifies Finder's process ID, then walks at most 14 AX ancestors. Only hit rows, cells, icons, or small icon-and-label groups qualify. URL/path attributes take precedence; leaf traversal stays within that item. A filename fallback requires that item's name label and a verified directory context. In list view it reads the name cell of the hit row, even if the cursor lies over Size or Date. Hidden extensions and localized display names are resolved only when unique, with a bounded two-second directory cache. Toolbars, sidebar controls, path bars, blank viewports, menus, and rename editors do not qualify.

Finder need not be foreground: a visible Finder item can start a dwell while another app remains active, without a preliminary click. This requires a system-wide hit belonging to Finder, not merely a Finder window behind another app. Observations distinguish foreground Finder from verified pointer ownership; neither an unrelated app nor an unverified stale node can activate an overlay.

Name-only fallback requires a complete scan of at most 2,000 direct siblings. It includes hidden siblings when checking exact, localized, and hidden-extension labels, and rejects conflicting AX label attributes. A truncated or failed scan cannot establish uniqueness, so that fallback is suppressed; trusted per-item URL/path attributes remain usable in larger directories.

Native application/document packages (including apps and Xcode projects) are treated as file HUD items; asset catalogs remain expandable folders.

Column views use per-item file URLs or directory URLs on the hit column's container. Where macOS exposes neither, Hoover suppresses the hover rather than combining a row name with the window document URL for another column. That conservative fallback can omit previews in some Finder/OS column-view AX configurations. Actual icon, list, and column-view behavior must be checked on macOS with Accessibility permission granted.

The pointer and published bounds use AppKit screen coordinates. The conversion reflects Quartz's global Y axis around the primary display, preserving positions on displays above, below, or left of it. It does not reflect around the hovered secondary display.

Observations include the source Finder window token and a bounded snapshot of non-minimized live Finder windows. Incomplete or failed window snapshots are represented as unknown (`nil`), so they cannot falsely dismiss a session. The app coordinator can dismiss a folder session when its original window closes or is minimized, while keeping it open during ordinary pointer exploration. Desktop items have no source window token. While Hoover itself owns a foreground key/modal window, only window lifetime snapshots continue; new Finder hover items are never resolved behind the active panel. Closing onboarding with no key/modal window allows Finder hit testing to resume even if the accessory app remains foreground. A key/modal window appearing during a probe discards that hit before delivery.

Held mouse buttons/dragging, focused Finder text editors, open context menus, and modal Finder sheets clear item observations. Switching apps dismisses the old session; a fresh dwell over a verified visible Finder item can start another. Accessibility permission is checked every two seconds, with prompts only on an explicit user request. The app coordinator owns folder/file delays, Escape dismissal, and whether an active overlay remains open while the pointer moves from Finder into Hoover.

## macOS acceptance checks

1. In icon view, hover an unselected folder for three seconds, then hover a file. Verify each result identifies the hovered item, regardless of selection.
2. In list view, hover Name, Size, Date, and Kind cells on different rows. All cells should resolve the actual row's file, never a similarly named file matching cell metadata.
3. In column view, hover files in both the current and previous columns. Verify the item URL or suppress ambiguous previews.
4. Move across blank space, the sidebar, path bar, and toolbar. Hover observations should clear.
5. Begin a drag, rename, or right-click menu while a dwell is pending. Activation should cancel; visible file metadata should dismiss.
6. Move into Hoover's overlay, switch apps, close Finder windows, and restart Finder. Verify coordinator retention and dismissal, with no stale file result.
7. Arrange a second screen above, below, and left of the primary screen. Verify HUD anchors align with hovered items in all arrangements.
8. Toggle Accessibility permission in System Settings. Verify onboarding state recovers without restarting Hoover.
9. Leave another app foreground, then hover an exposed Finder folder without clicking. Verify its own children appear after the full dwell. Cover that folder with the other app's window; no Finder item should activate behind it. Repeat after closing Hoover's permission window, and verify active Hoover settings/modal windows suppress new background hover.

FinderHover was studied as a behavioral and API reference. This tracker is independently implemented; no FinderHover source was copied.
