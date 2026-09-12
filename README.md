# StorageDaddy

A free, open-source Mac storage analyzer for developers. Find large folders,
understand caches and build output, and review every cleanup before moving
anything to Trash.

[Download the Mac app](https://storagedaddy.significanthobbies.com/download) ·
[Website](https://storagedaddy.significanthobbies.com/) ·
[Report an issue](https://github.com/sarthakagrawal927/storagedaddy/issues)

![StorageDaddy exploring a generated demo folder](site/public/storagedaddy/assets/storage-explorer.png)

The screenshot shows the real app with generated demonstration files. Its
sizes and timing are not a whole-disk benchmark.

## What's included

- A native SwiftUI and AppKit explorer with live scan results, treemap and
  other visual views, folder drill-down, sorting and an inspector.
- Developer Insights for caches, builds, packages, node_modules, Git data and
  recognized AI storage. Scan time, entries per second and sampled memory
  make the cost of scanning visible.
- Reviewed cleanup: stage candidates, inspect warnings, then confirm a move
  to Trash. Scanning never deletes files, and the app never empties Trash.
- Installed applications with icons, sizes, last-used metadata, categories
  and reviewed removal of eligible apps.
- AI Sessions for standard Claude and Codex transcript locations, independent
  of a disk scan. Older conversations can be exported locally before cleanup.
- **AI Context (Beta)**: expandable projects, shared Global Skills, source
  previews and per-agent instruction estimates. These are partial estimates,
  not measurements of an agent's live prompt.
- Saved snapshots in History and signed updates through Sparkle.

## Install

The public DMG is Developer ID signed, notarized and stapled. It supports
**Apple silicon Macs with macOS 14 or later**. Download it, drag StorageDaddy
into Applications and open it. Choose a disk or a folder to scan. Full Disk
Access is optional and helps with protected locations.

Automatic update checks are enabled by default. Installing an update requires
confirmation. The app menu also provides **Check for Updates…**.

## Build from source

Requirements: macOS 14+, Xcode with Swift 6, Python 3, Git, and Rust 1.82+
with Cargo for the Memory Pack helper. Dependencies are pinned with
`Package.resolved` and `Vendor/MemoryPack/Cargo.lock`.

```sh
git clone https://github.com/sarthakagrawal927/storagedaddy.git
cd storagedaddy
swift build -c release

# Build the included, compatible archive helper.
python3 prepare-memory-pack.py --source Vendor/MemoryPack --build
python3 package-app.py
open artifacts/StorageDaddy.app
```

The package script creates an ad-hoc signed development app. It increments a
local build number; it does not reproduce the signing or build number of the
public DMG. Signing keys and notarization credentials are not included. The
checked-in Sparkle key is public and cannot sign updates. For a fork, configure
your own update feed and signing key before distribution.

```sh
swift test
python3 -m unittest test_sparkle_support
cargo test --locked --manifest-path Vendor/MemoryPack/Cargo.toml
```

## Landing page

The static landing and Cloudflare Worker are under `site/`.

```sh
cd site
npm ci
npm run check
```

To preview the static page without Cloudflare, run
`python3 -m http.server 8792 --directory site/public/storagedaddy` from the
repository root. Public DMGs are hosted on the website and excluded from Git.
The deployment script requires the exact qualified DMG from `site/release.json`
to be present locally. Publishing updates additionally requires the owner's
Developer ID, notarization profile and Sparkle signing key.

## Privacy and limits

File processing stays on your Mac. There are no file uploads or AI calls.
Sparkle uses HTTPS to check for and download updates. Website request counts
are separate from app activity.

Scans can be partial when macOS denies access. On-disk sizes reflect allocated
storage; shared APFS blocks, hard links and snapshots mean totals are not a
promise of space reclaimed. Trash continues to occupy storage until you empty
it. Application associations and developer classifications are best-effort.

AI session counts describe transcript files, including nested subagent files,
not necessarily distinct conversations. Custom agent home folders are not
covered by the standard-location inventory. AI Context has bounded discovery
and cannot prove which instructions, rules or tools a running agent loaded.

Conversation archives retain supported prompts, replies and metadata while
omitting bulky tool traffic, attachments and other records. They are lossy
reading exports, not resumable backups. Exporting alone frees no space.
Original removal is a separate verified and confirmed cleanup action. Review
exports before sharing: credential masking is best-effort.

## License and acknowledgments

StorageDaddy's original code and documentation are available under the
[MIT license](LICENSE). Third-party libraries and provider artwork retain their
own terms; see [Third-party notices](THIRD_PARTY_NOTICES.md). Acknowledgments
are also available in the app menu.
