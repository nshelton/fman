# Fman

A small macOS file browser focused on folder sizes. Plain C scanner, native AppKit UI in Objective-C. No third-party dependencies.

## Build and run

Requires macOS 13 or later and the Xcode command-line tools.

```sh
make setup-signing
make
open build/Fman.app
```

`make setup-signing` is a one-time local setup. It creates a **Fman Development** certificate and private key in your login keychain, trusts the certificate for code signing only, and allows `/usr/bin/codesign` to use the key. macOS may ask you to authorize the keychain change. Temporary key/export files are removed. Re-running setup keeps the existing identity. The key is not stored in the project or removed by `make clean`.

On the first signed build, macOS may ask to let **codesign** use **Fman Development**. Approve that Keychain dialog with **Always Allow** to remember it. Enter your password in the macOS dialog only. This signing approval is separate from the app's Full Disk Access permission below.

Builds use this same signing identity so macOS can recognize Fman after code changes. This is for local development, not distribution. To use an existing Apple signing identity instead, pass `SIGN_IDENTITY="your certificate name"` to `make`. Changing identities requires granting permissions again.

Or `make run`. The GUI always scans `/` and displays one tree rooted at **Macintosh HD /**. The root stays expanded. There is no folder picker, navigation history, or alternate GUI scan root.

Click a folder row or its disclosure arrow to expand or collapse it in place. Left/Right arrows and Return also control expansion. Every folder sorts its own children largest first. Expanded branches and selection survive live size updates and switching between allocated and logical sizes. Each row's background fills green across its full width to show its share of its parent, with the percentage beside the size. Selection adds an outline so the size fill remains visible. Command-R rescans `/` and resets the tree.

The full-width bar at the top represents the startup disk's total capacity, filled green for used space, with used/free labels. These figures come directly from macOS and update independently of scanning and the logical/allocated toggle. Used space is total capacity minus reported free space, including APFS storage outside the accessible file tree. Scanned file totals appear below the bar and in the root row.

Below the capacity bar, the SSD health row shows reported health, estimated endurance used, lifetime host writes in decimal TB, and temperature. **Details** expands the drive model, lifetime reads, available spare and its warning threshold, power-on hours, power cycles, unsafe shutdowns, media errors, error-log entries, controller busy time, and last successful check. Health reads run in the background at launch and every minute, independently of scanning.

The reader follows the startup volume's IOKit ancestry to its NVMe SMART device, rather than assuming `disk0`. It uses Apple's native NVMe interface and requires no installed utilities or privileged helper. Unsupported drives or failed reads show “SSD health unavailable” and clear the counters. This view currently supports NVMe SMART data; it does not collect historical samples.

Health counters cover the physical SSD across its volumes. Endurance used is a manufacturer estimate rounded to whole percent, can exceed 100%, and is not a prediction of remaining life. Available spare is reserve flash, not free disk space. Critical warnings, recorded media errors, exhausted estimated endurance, or spare below its threshold show “SSD needs attention,” with the reason in Details. Unsafe shutdowns and error-log entries alone do not trigger that status. “No warnings reported” is not a guarantee against failure.

Right-click an entry to expand/collapse it, open a file, show it in Finder, copy its path, or move it to Trash. Trash is available after scanning stops and requires confirmation. The root cannot be trashed. App bundles expand like folders. Double-clicking a file opens it in its default application.

## Scanner

```sh
./build/fman-scan /path/to/folder
./build/fman-scan /path/to/folder 1
./build/fman-scan /path/to/folder 8
make test
```

The optional argument is worker count (default 8, maximum 32). Control-C cancels the command-line scan and prints partial results. Exit status is 0 for a completed scan without errors, 1 for unreadable entries, or 130 for cancellation.

The scanner uses `getattrlistbulk` with a 256 KiB buffer per worker, a shared directory work queue, a flat node array, and an arena for names. It reads metadata, never file contents. Folder totals update after each batch. The UI snapshots expanded branches every 400 ms during scanning and draws only visible outline rows. AppKit item objects are created lazily as branches are browsed, with stable identities to preserve expansion. There is no database or background service.

`FMScan` exposes its fields directly. Hold `scan->mutex` when reading them while scanning, including when calling `fm_path`; free the returned path. `fm_free` cancels and joins all workers before releasing memory. The UI releases old scans on a background queue so cancellation does not block the window.

## What the sizes mean

- **On disk** sums allocated file sizes, including resource forks. Hard links count allocation once across the scan; the first encountered path gets the allocation and later paths show “Shared link.” Folder attribution can vary with worker scheduling.
- **Logical** sums file lengths, including resource forks, at every path. Sparse files can have a large logical size and little allocated storage.
- Directory metadata is excluded. APFS clones can share blocks, and snapshots retain blocks outside the live tree. These numbers are not an exact prediction of space recovered by deleting a folder, and need not match the system's total used space.
- Hidden files are included. Symlinks are measured without traversing their targets. Nested mount points and automount triggers are listed but not traversed. On `/`, data reachable through firmlinks is traversed while the separate Data mount is skipped. The separate command-line scanner can still scan a supplied folder or volume.
- Permission errors propagate to parent folders. A `+` on a size means it is incomplete. Stopping a scan leaves explicitly partial results. A changing filesystem is observed as it is scanned, not as an atomic snapshot.

For protected folders, quit Fman, add `build/Fman.app` in **System Settings → Privacy & Security → Full Disk Access**, enable it, and relaunch. The app's **Full Disk Access…** button opens that pane. If an old ad-hoc build is already listed, remove that entry and add the newly signed app once. macOS owns this approval; the app cannot grant it to itself. Using the same signing certificate and bundle identifier lets macOS retain the grant across rebuilds. CLI scans inherit the permissions of their launching terminal. Some system paths remain restricted even with Full Disk Access.

## Initial measurements

On the development Mac, the GUI scanned 2,279,932 entries from `/` in 34.3 seconds, reporting 474 unreadable entries and 10 excluded mounts. This was an accessible-tree scan, not a complete physical-volume accounting.

A subsequent eight-worker scan of the Xcode macOS SDK tree processed 52,592 entries in 0.15 seconds with about 4 MiB of index capacity. Filesystem caches affect these results; these are observed runs, not controlled cold-cache benchmarks.

Tests exercise 12,533 entries with one and eight workers: multiple bulk buffers, folder aggregation, sparse files, hard-link deduplication, symlinks and loops, Unicode names, permission errors, cancellation, and invalid roots.
