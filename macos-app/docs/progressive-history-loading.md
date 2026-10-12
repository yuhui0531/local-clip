# LocalClip 0.3.6 (28): category drop, confirmation and progressive loading

The current architecture supports progressive loading without a schema change: `HistoryStore` already returns ordered summary pages with revision-bound cursors, and the existing horizontal history strip uses `LazyHStack` with stable record IDs. Loading 50 summaries before the first draw was unnecessary for a viewport that displays about 10 cards. This follow-up changes the loading policy while preserving the Paste-style horizontal layout; the existing vertical-wheel-to-horizontal-scroll behavior remains.

## Implementation

- Configure screen width and actual square-card size before the first history query. Fetch only enough summaries to cover that viewport; resize during a query fills the latest viewport rather than leaving an empty gap.
- After actual scrolling, prefetch within one viewport of the loaded end. A normal batch covers two viewports, bounded to 8–50 records. Geometry callbacks share one in-flight paging task; entering the panel or speculative lazy-view creation does not cascade through all pages.
- Reuse the existing revision/query-signature/offset cursors. Normal browsing reads one extra row to determine whether another page exists, avoiding a separate full result count per page. Deep offsets and literal search retain their existing SQLite costs; this is not a keyset-pagination or search-index redesign.
- Publish a completed page atomically. Query generations and cancellation reject stale results. End and Select All take ownership from prefetch, so repeated commands cannot append the same page twice. Keyboard and Shift navigation crossing an in-flight page retain the intended selection.
- Keep selection and detail by record ID. Refresh preserves the loaded range, and restores the first visible record plus its pixel offset when earlier records are inserted, removed or reordered. Filter/query changes intentionally reset to the first page.
- Keep lazy, equatable cards. Decode thumbnails only while their card is visible; cancel work and release decoded images offscreen. The existing encoded-thumbnail LRU remains capped at 16 MiB and 256 entries. Visited lightweight summaries remain available for backward scrolling and multi-selection; they are not an unbounded cache of full clipboard payloads, but their count still grows with the visited range. Explicit End/Select All can still load all summaries as requested.

## Custom-category drop

The drag bridge was still consuming `leftMouseDragged` and `leftMouseUp` after starting an AppKit native drag. AppKit needs those events to complete the native destination drop. The bridge now hands them through for the native session and performs cleanup in the native drag-ended callback. Pre-session hit testing, held-button checks, source identity and frozen selection remain.

The short internal category token is written eagerly, while public export representations retain their existing promise behavior. The actual category target validates the current session token and claims it once before persisting membership. External, forged or replayed tokens do not import data. Category assignment does not change clipboard bytes or copy the record's payload.

## Confirmation

The previous generic `NSAlert` used the oversized default app icon and technical disk-accounting text. A compact SwiftUI content view now appears in a native sheet, with a small symbol, operation-specific title/action, concise consequences and an explicit deletion count. Zero deletions read “当前不会删除任何记录”; unlimited retention explains that expiration cleanup is disabled while capacity rules remain. Escape, Cancel and parent closure cancel once. The existing preview/revision confirmation policy is unchanged. Focus dismissal is suspended while confirmation is active.

## Why a candidate database still exists

The original design was an overly conservative choice: changing an independent candidate let capacity checks and failures leave the live history untouched before an atomic replacement. The previous implementation also rechecked the whole database and payload set for each small write; that repeated work was unnecessary.

The earlier LC-06 correction, retained here, removes repeated whole-payload and integrity scans on the validated APFS clone path. An APFS clone is a distinct logical file sharing unchanged blocks through copy-on-write, not a byte-for-byte rewrite of the database. Full validation remains at startup/recovery and for untrusted or non-clone fallback paths. SQLite constraints, operation identity, fsync, atomic replacement and quota checks remain. Metadata counts, allocation accounting and cleanup still have costs that can scale; this does not make every write constant-time. In-place transactions are not enabled without addressing the existing no-loss and journal/quota contract.

## Verification and measurement

Final Debug: 99 discovered, 86 passed, 13 conditional skips, no failures (log). Final Release with named pasteboards enabled: 99 discovered, 92 passed, 7 conditional skips, no failures (log). The Release category regression goes through the actual export writers, named pasteboard, category target and persisted assignment, and rejects a repeated/forged token. Other regressions cover order, coalesced prefetch, stale query cancellation, resize, selection/detail, scroll restoration and repeated bulk navigation, alongside the existing capture/output/quota/crash tests. Conditional long benchmarks are not counted as passed by these suites. Tests use synthetic SQLite stores, fake system clients and opted-in temporary named pasteboards; they do not access the general clipboard or production history.

The isolated loading benchmark copies the existing 10,100-record synthetic store (10,000 text records and 100 real image payloads, about 226 MiB). It compares the **same current Release query implementation** with fixed 50-row versus viewport 10-row initial requests, alternating their order for 200 samples each; 20-row continuation prefetch also has 200 samples (raw samples, test log).

| Service query | Rows returned | P95 | Maximum |
|---|---:|---:|---:|
| Fixed initial request | 50 | 0.823 ms | 1.934 ms |
| Viewport initial request | 10 | 0.674 ms | 0.864 ms |
| Continuation prefetch | 20 | 0.753 ms | 0.830 ms |

This representative viewport loads 80% fewer initial summaries and reduces query-return P95 by 18.1% in this sample. The first records in this fixture are images, so their preview/context UTF-8 counters are zero; those counters do not measure Swift object memory. No RSS reduction, frame-rate improvement, cold-start improvement or physical-GUI smoothness is claimed. The timings exclude startup, AppKit input and drawing, and are not a before/after build27 benchmark.

The source/build manifest is artifacts-0.3.6.json. The independent follow-up is the review report. The original build27 app, source archive and manifest are preserved in `evidence/review-fixes/progressive-loading-20261011/baseline-build27/`.

Physical drag gestures, sheet appearance/keyboard behavior and perceived scrolling smoothness are left to the user, as explicitly requested. Automated native event handoff and named-pasteboard destination persistence are separate evidence. This turn does not launch/install the app, send keys to target apps, or repeat the earlier build26 GUI/idle/storage scaling measurements.
