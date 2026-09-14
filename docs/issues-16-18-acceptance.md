# Issues 16 and 18: acceptance, 14 September 2026

## Scanner evaluation (#16)

Keep the existing parallel Swift metadata scanner and sequential/Foundation fallbacks. Pack the two DiskNode flags beside its optional parent: arm64 node stride falls from 96 to 88 bytes, with unchanged public fields and Codable schema. No metadata, cleanup checks or filesystem boundaries were removed. No production dependency was added.

Three alternating fresh release processes per variant scanned the same startup-data target with 16 readers and live-progress bookkeeping. The live tree grew from 7,224,234 to 7,224,546 entries; all six scans reported 26,236 skipped entries. Cache state was uncontrolled. Exact ordered metadata/topology parity is established by stable fixtures, not the changing real-tree totals.

| Metric | Build 79 control | Packed nodes |
| --- | ---: | ---: |
| Median scan seconds | 30.352 | 29.615 |
| Maximum observed process RSS | 2.160 GB | 1.833 GB |
| Node stride | 96 bytes | 88 bytes |

The observed memory maximum fell 15.1%; elapsed improvement was 2.4%, too small to call a substantial speed breakthrough. Candidate physical disk reads were 116.9–119.5 MB/s; these are process I/O counters, not logical bytes discovered. Peak RSS varies with allocation/cache pressure; this is an observed workload bound, not a universal cap.

The 10x / 5–10-second target is **not achieved**. Earlier measured parallel traversal improvements remain in place. No faster replacement engine was justified by the existing parity/performance evidence.

Incremental evaluation rejected directory-timestamp-only reuse: overwriting a nested fixture file changed its size while leaving both its containing-directory and scan-root mtimes unchanged. Current rescans remain fresh full scans. A future incremental design would need independent dirty tracking, restart/lost-event recovery, permission/mount/exclusion invalidation, and final cleanup revalidation. It cannot inherit fresh-scan performance claims from cached results.

Local reproducibility and raw evidence:

- `Experiments/scanner-speed/benchmark.py /System/Volumes/Data --rounds 3 --variants baseline,parallel16 --baseline artifacts/performance/StorageBench-build79 --baseline-workers 16 --output artifacts/performance/issue16-memory-startup.json`
- `artifacts/performance/issue16-memory-startup.json` records commands, binary SHA-256, elapsed/wall time, counts, allocation, skips, RSS and physical I/O where the binary supports it.
- `artifacts/performance/issue16-incremental-evaluation.json` records the stale-cache counterexample.
- `StorageBench scan` now emits entries/s, physical-read bytes, peak/retained RSS, node stride and capacity as a machine-readable JSON line. Older benchmark binaries explicitly have no physical-I/O measurement.

## Utility acceptance (#18)

The previously pending native checks were exercised on the installed app:

- Applications: independent discovery, search/reset, header sorting and repeat-click reversal, category groups, review/cancel of Bruno with its bundle preserved. System apps, running apps and storagedaddy show protected removal actions.
- AI Context: initial loading, partial coverage notice, retained-results refresh, project search/reset, inline expansion/collapse, exact-directory agent estimates, separate Global Skills, second-page skills and file preview.
- AI Sessions: independent inventory and combined Codex/project filtering.
- History: synthetic two-file scan, Save Snapshot without redirect, History listing, quit/relaunch, and historical top-level details without a new scan. One clearly named `issue18-acceptance-fixture` snapshot remains as acceptance evidence.
- Compact 961×629 and wide native windows inspected. No new visual direction or UI dependency. Full VoiceOver, enlarged text and exact 880-point minimum were not qualified.

Refresh providers are injectable for deterministic tests. Four model tests induce failure after success and overlap old/new requests for both AI tools: retained results stay available, errors are exposed and stale completions cannot replace newer results. Applications now explicitly labels failed refreshes over previous inventory. Error rendering is covered by model state plus source review; a live filesystem failure was not induced by changing user permissions.

`swift test`: 148 DiskCore tests plus 4 inventory refresh tests pass. `swift build -c release` passes. Native design acceptance preserves DESIGN.md: critique 34/40, audit 17/20, no P0/P1 findings; desktop evidence substitutes for web breakpoints under the existing native exception. Screenshots and receipt are in `artifacts/design/issue18-*` and `.fleet/issue18-design-review.json`.

Installed build 80 is Developer ID signed and notarized; its executable matches the signed candidate. Native startup-data acceptance: 6,335,438 files, 521.58 GB allocated, 26,182 skipped, 29.41 s scan / 32.15 s including insights, 255,532 entries/s, 123.7 MB/s physical Metadata I/O and 2.04 GB sampled app RSS. Native app permissions/coverage differ from CLI measurements, so these are not direct before/after ratios. Rescan cancellation restores the complete prior result and its RSS. Build 79 is preserved in a local backup. The subsequent owner-authorized release publishes this same qualified build 80.
