<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="DiskScope icon">
</p>

# DiskScope

A fast, fully-offline disk-usage inspector for macOS with a Miller-columns
interface, in the spirit of OmniDiskSweeper. Scan any volume or folder, browse
into the largest space hogs column by column, and reclaim space by moving items
to the Trash.

## Why

When a drive fills up, you want to find the biggest folders and files quickly
and decide what to remove. DiskScope shows on-disk sizes for every entry,
sorted largest-first, and lets you drill down through a cascade of columns just
like the Finder's column view.

## Features

- **Fast.** A parallel scanner built on `getattrlistbulk(2)` (one bulk
  metadata syscall per directory) measures a quarter-million files in well
  under a second — roughly **3–5× faster** than a naive `FileManager` walk, and
  on par with or faster than `du`.
- **Persistent cache.** Re-opening a volume loads the previous scan **instantly**
  (tens of milliseconds instead of seconds), with a real freshness check so you
  know when it's out of date.
- **Miller-columns browser.** Each directory you select opens a new column to
  its right, so the path from root to the current item stays visible.
- **On-disk (allocated) sizes**, summed bottom-up for every folder, sorted
  largest-first. Totals match `du` exactly.
- **No double-counting.** APFS firmlinks make the Data volume's contents
  reachable through several paths (`/Users` *and*
  `/System/Volumes/Data/Users`, …). DiskScope deduplicates by filesystem
  identity so each directory is counted once, under the path you expect.
- **Live scanning.** Sizes grow in real time as the scan descends — you can
  start browsing before it finishes.
- **Size "heat" coloring** (log-scaled) plus a faint proportional bar behind
  each row, so the biggest items pop visually.
- **Keyboard navigation.** `↑`/`↓` move within a column, `→` descends into a
  folder, `←` goes back up, `⌘⇧C` copies the selection's path, `⌘⌫` moves the
  selection to the Trash.
- **Reclaim space safely.** Deletion always goes through the Trash
  (`FileManager.trashItem`) — it is reversible and never a destructive `rm`.
- **Reveal in Finder** for any selected item, and **Copy Path** (also available
  from the right-click menu on any row).
- **Disk-independent.** Scan the boot drive, any mounted external volume, or an
  arbitrary folder you pick.

## Privacy / offline guarantee

DiskScope **never accesses the network.** The only frameworks it links are
Foundation, SwiftUI, and AppKit; there is no networking code anywhere in the
source. The bundle's `Info.plist` additionally sets App Transport Security to
deny all outbound connections, so the guarantee is enforced by the OS, not just
by convention. Everything runs locally on your machine.

## Requirements

- macOS 14 (Sonoma) or later
- The Swift toolchain (full Xcode **not** required — the Command Line Tools are
  enough): `xcode-select --install`

## Build & run

```sh
make run        # build a release .app bundle and launch it
make app        # just build .build/DiskScope.app
make debug      # debug build + launch
make icon       # regenerate the app icon (scripts/generate_icon.swift)
make clean
```

`make app` assembles `.build/DiskScope.app`, which you can drag to
`/Applications`.

## Full Disk Access

macOS protects some locations (other users' folders, parts of the system,
Mail, Messages, and so on). Those appear in DiskScope with a lock icon and a
size of 0 until you grant access:

> System Settings → Privacy & Security → Full Disk Access → add
> **DiskScope.app**

Your own home folder and most of the boot drive scan fine without it. The app
degrades gracefully — unreadable folders are skipped and marked, never crashed.

## Performance

Two techniques do the heavy lifting:

1. **Bulk metadata syscalls.** Instead of listing a directory and then calling
   `stat` on every entry (the usual `FileManager` + `URLResourceValues` path),
   the scanner uses `getattrlistbulk(2)` to fetch name, type, on-disk allocated
   size, modification time and device id for many entries in a single kernel
   call. See `FastDirectoryScanner.swift`.
2. **Parallel walk.** A small worker pool pulls directories from a shared stack
   and enumerates them concurrently. On SSD/APFS the bottleneck is syscall
   latency, not disk seek, so this scales well. Directory totals propagate up
   the tree once per completed subtree rather than once per file, keeping lock
   traffic proportional to the directory count.

Measured on an Apple-silicon Mac (`--benchmark --compare`):

| Target          | Files   | Old (serial FileManager) | DiskScope (parallel) | Speedup |
|-----------------|---------|--------------------------|----------------------|---------|
| `/Applications` | 247,562 | 1.55 s                   | 0.52 s               | ~3×     |
| `~/Library`     | 571,064 | 12.60 s                  | 2.38 s               | ~5.3×   |

Reported totals match `du -sk` to the byte.

## Caching & freshness

After a scan, the whole tree is written to a compact binary cache in
`~/Library/Application Support/DiskScope/`. Re-opening the same volume loads it
in tens of milliseconds instead of re-scanning (measured ~89 ms warm vs ~6 s
cold — a ~68× first-paint speedup).

Because a stale cache is worse than no cache, validity is checked on two levels:

- **Global (O(1)):** the volume's free space and capacity at scan time are
  stored and compared to live values on load. Material drift flags the cache as
  stale in the UI (an amber banner) so you can rescan with one click.
- **Per-directory (on navigation):** each directory's modification time is
  captured during the scan (free, via the same bulk syscall). When you open a
  folder from a cached tree, DiskScope stats just that one folder; if its mtime
  changed, that subtree is re-scanned in the background and the sizes update in
  place.

A full **Rescan** is always one click away, and never touches the network.

## How it works

- `ScanCoordinator` owns the parallel scan, progress, caching and freshness
  logic. The tree (`FileNode`) is mutated only under a lock; the UI reads
  snapshots through `sortedChildren(of:)`, so there is no data race. Views
  refresh off a throttled tick during scanning. A monotonically increasing
  generation supersedes stale scans and background refreshes.
- File sizes are attributed up the parent chain, so directory totals are always
  the sum of everything beneath them.
- To keep memory reasonable on large drives, nodes store only a name and a
  parent link; absolute URLs are reconstructed on demand.

### macOS volume groups & firmlinks

Scanning `/` on modern macOS is deceptively hard: the boot drive is an APFS
*volume group* where the read-only System volume and the read-write Data volume
are stitched together with **firmlinks**. As a result the same directory is
reachable through multiple paths — `/Users` and `/System/Volumes/Data/Users`
are literally the same directory — and, crucially, both report the *same*
`st_dev`, so a device-id mount check cannot tell them apart. A naive walk counts
the entire Data volume two or more times (we measured 506 GB → the real figure
is ~263 GB, and with Full Disk Access it inflated past 1 TB).

DiskScope handles this by tracking each directory's `(device, inode)` identity
and counting it only once. Because firmlink aliases share an inode, the
duplicate is skipped. The walk is **breadth-first**, so the shallower,
user-facing path (`/Users`) is counted and the deep internal one
(`/System/Volumes/Data/Users`) collapses to zero — totals are correct *and*
sizes appear where you expect them. This also neutralizes hardlinked
directories and bind-style aliases for free.

### Developer CLI flags

The app binary doubles as a dev tool (these exit before any UI):

```sh
.build/release/DiskScope --selftest  <path>              # verify the bulk parser vs FileManager
.build/release/DiskScope --benchmark <path> [--compare]  # time a scan (optionally A/B vs old approach)
.build/release/DiskScope --benchmark <path> --cachetest  # cold-scan vs warm-cache-load
```

## Project layout

```
Sources/DiskScope/
  App/          DiskScopeApp.swift      — @main entry + app activation
  Model/        FileNode, Volume, ByteFormat (+ theme/colors)
  Scan/         ScanCoordinator         — parallel scan, progress, caching
                FastDirectoryScanner    — getattrlistbulk bulk enumeration
                DiskCache               — compact binary cache + validity
                SelfTest, Benchmark     — CLI dev tools (gated by flags)
  Services/     FileActions             — Trash + Reveal (local-only)
  Views/        ContentView, MillerColumnsView, ColumnView, RowView,
                ScanBar, BottomBar, EmptyStateView
scripts/bundle.sh                       — assembles the .app bundle
scripts/generate_icon.swift             — draws the app icon (Core Graphics)
Resources/Info.plist                    — bundle metadata + ATS deny-all
Resources/AppIcon.icns                  — app icon
```

## License

MIT — see [LICENSE](LICENSE).
