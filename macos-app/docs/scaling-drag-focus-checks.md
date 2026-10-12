# LocalClip 0.3.5 — LC-06, drag identity and focus follow-up

Baseline: `87c71a2`. Final delivery 0.3.5 (27). GUI performance measurements belong to build 26; the later correction changes drag preparation/completion only. This follow-up addresses the remaining LC-06 scaling cost and the user's drag/focus reports. Prior 0.3.4 app/archive evidence is preserved under `evidence/review-fixes/reviewed-0.3.4/`.

## Changes

Validated APFS COW candidates no longer prefetch every payload or repeat whole-database quick/FK checks on every small write. Startup and recovery still validate the database; initialization, untrusted sources and SQLite-backup fallback still check candidates fully. SQLite FK/CHECK constraints, DELETE/FULL journaling, actual allocation/quota checks, fsync/F_FULLFSYNC, atomic replacement, directory sync and post-commit identity verification remain. Blob collection uses deleted representation digests and an indexed NULL-orphan cleanup. This removes the full-payload scan from routine writes; metadata, APFS extent operations, non-APFS backup and quota reclamation can still scale with the store.

A card's native monitor owns its complete left-button gesture and captures its ID and modifiers at mouse-down. The hit area intersects the card's own bounds with its visible area: an unclipped NSView's visibleRect alone covers the whole scroll viewport. Selection and exported IDs stay frozen until the session ends. Completion then reconciles selection against visible records: keep a surviving source, otherwise choose its nearest surviving neighbor from the captured order, or clear selection/metadata/detail if none remain. The drag image is the actual card snapshot, with source lift/fade, native pile formation and cancellation return animation; Reduce Motion disables the spring.

Panel dismissal now also observes external mouse-down, including a click in the already-active external app. Dismissal waits through native drag, menu tracking and modal interactions, then checks focus again. This uses mouse observation without key interception or permission expansion.

## Evidence and limits

All data are synthetic. The GUI check uses a distinct bundle ID, named pasteboard and isolated database. It runs optimized Swift with DEBUG instrumentation and a regular application host to make the nonactivating panel accessible to automation. The final production Release has no injection/configuration/benchmark entry points. UI checks and AppKit completion timings apply to that isolated optimized host, not a general-clipboard/production-target session. The running production app and its history were not opened or taken over.

Raw evidence: scaling and GUI run.

| Database size | Text insert P95 | Settings P95 | Dedup P95 |
|---|---:|---:|---:|
| 10.13 MiB | 10.894 ms | 10.005 ms | 10.997 ms |
| 100.35 MiB | 12.404 ms | 11.365 ms | 12.174 ms |
| 226.62 MiB | 15.187 ms | 13.220 ms | 14.677 ms |
| 481.19 MiB | 18.270 ms | 15.947 ms | 18.034 ms |

40 Release samples per operation per size, fixed 16-blob synthetic scaling fixture; not an image-decoding or record-count scaling test. Final integrity/FK checks pass at all four sizes. Nearest-rank P95. Raw arrays.

Production service benchmark uses v2 seed `0xC11F`, 10,000 texts and 100 real encoded images (226 MiB). HistoryStore-call-to-return P95: search 55.842 ms (200), first page 1.924 ms (200), text commit 52.860 ms (200), new PNG commit 58.789 ms (20), near-quota commit 415.218 ms (30). The image maximum 664.178 ms is retained. This excludes polling/input/rendering. Raw service arrays and manifests.

## Isolated GUI timings

The build 26 natural-draw sampler uses a 10,000-text/100-image fixture, initially 226 MiB. PNG/TIFF/JPEG are actual encoded 1920×1080 images. Text/image capture runs use the production 200 ms polling and persistence/refresh/thumbnail pipeline with a private NSPasteboard. All samples and slow outliers remain in the raw arrays. GUI measurements cover this dataset; the four-size table above covers storage operations only.

| Measurement | Samples | P95 | Maximum | Target comparison |
|---|---:|---:|---:|---|
| Cold launch, AppDelegate start to draw | 10 | 1432.858 ms | 1432.858 ms | Report separately; excludes process loader |
| Warm show closure to draw | 200 | 152.846 ms | 229.357 ms | Misses <150 ms |
| Cold search dispatch to draw | 100 | 250.213 ms | 273.502 ms | Misses <100 ms |
| Warm search dispatch to draw | 100 | 291.988 ms | 312.880 ms | Misses <100 ms |
| All fixed searches | 200 | 280.553 ms | 312.880 ms | Misses <100 ms |
| Text write to draw | 200 | 416.235 ms | 1504.853 ms | Within 500 ms P95 in isolated host; outlier retained |
| New PNG write to thumbnail draw | 20 | 618.135 ms | 620.954 ms | Misses <500 ms |

Computed results, raw arrays, 10 final cold launches, source/binary provenance.

Timing ends after a natural AppKit witness draw and the subsequent CATransaction completion. Warm-open starts at the shared show closure, search starts at model dispatch and includes the current 20 ms debounce, and copy starts immediately before the named-board write. These differ from physical shortcut/input and source-write-completion boundaries in the acceptance plan. They include app-side work but exclude tool input transport and GPU scanout. A regular optimized DEBUG host differs from production activation policy. Thus this is GUI diagnostic evidence, with explicit missed budgets; it does not establish full AC16 production acceptance.

The first sampler forced a second full-window display; its 200 warm-open samples (P95 154.978 ms) are retained in `gui-226/invalid-run-1`. That run then failed because the capture policy was paused during cold-search fixture insertion. The corrected sampler observes natural drawing, enables capture explicitly and finishes every required sample group. Earlier 10-launch data remain separately in `cold-launches.json`; the table uses `cold-launches-final.json` and the measured build 26 GUI binary throughout.

## Live interactions

Isolated checks confirm category creation, literal search input, second-card coordinate selection, stable source selection during preparation/cancellation, menu focus retention and Escape dismissal. Native event capture exposed and verified the bounds fix: each card now has its own disjoint hit area rather than the full viewport. These live checks preceded the final asynchronous gesture-identity guard. That guard was compiled and model regressions passed; its native event conditions were not exercised by those regressions and remain unverified.

CUA sends left-down/drag/up while `NSEvent.pressedMouseButtons` remains zero. The production held-button check correctly cancels; no `native-session-started` callback occurred. Therefore physical native drop, preview movement and cancellation animation remain **unverified**. Targeted TextEdit AX/coordinate input also left the LocalClip panel key and delivered no OS activation/global mouse event. Actual outside-click/focus dismissal remains **unverified**. No permissions or real clipboard/history data were changed to bypass these tool limits.

## Capture pressure and regression checks

Release stress arrays use the real named NSPasteboard and production capture/store on a synthetic clone, without GUI rendering:

| Source interval | Inputs | Saved | Explicit skips | Unobserved changes |
|---|---:|---:|---:|---:|
| 1000 ms | 100 | 100 | 0 | 0 |
| 500 ms | 100 | 100 | 0 | 0 |
| 200 ms | 100 | 89 | 0 | 11 |
| 50 ms | 100 | 27 | 0 | 73 |

Single-board changes overwritten before observation cannot be recovered. Actual source-write completion times are retained. The stress-only test completed in 193.922 seconds and explicitly did not measure idle in its test host. Execution log.

Build 26 primary-source regressions: Release, 91 discovered / 85 passed / 6 conditional skips; Debug, 91 / 80 / 11. The opt-in scaling, service, fixture and stress runs described above were executed separately; other conditional checks were not expanded by this follow-up. The later test-host stress-only switch was compiled and executed by the dedicated stress run. The build 26 production Release build and strict ad-hoc signature verification pass; version 0.3.5 (26), arm64, minimum macOS 15.0. Release strings contain no GUI configuration, named test-data injection or benchmark commands.

## Idle resources and delivery

Idle results and 120 raw samples: 10 s warmup, then 605.863 s measured, capture enabled on the unchanged private board and panel hidden. CPU uses one-core percent: mean 0.618%, P95 1.896%, maximum 2.171%. Current RSS mean 118.537 MiB, sampled maximum 167.391 MiB, final 124.266 MiB. These are post-benchmark samples, not the process lifetime peak. Energy and wakeup counts are unavailable. No task builds/tests ran concurrently; other desktop apps were uncontrolled. Resource thresholds remain unspecified in the PRD.

The isolated store passes a final full integrity and FK check, and all 20 new PNG digests have persisted references. Capture is paused and the isolated test app is stopped. The running production app and user history remain untouched; the new build takes effect when that app is restarted.

Final build 27 artifact fingerprints and archive verification are in 0.3.5 artifacts. The source archive excludes databases, generated evidence, caches and app/test binaries. The prior reviewed 0.3.4 artifacts and earlier failed measurements remain preserved. The build 26 independent FAIL report found **IR-04**: a source removed during dragging could leave stale selection/detail after completion. The added deletion/expiry/empty-history regression reproduced the issue before repair. Build 27 corrects completion reconciliation; its final Debug/Release results are recorded below. Build 26 app/archive/manifest are preserved in `evidence/review-fixes/reviewed-0.3.5-b26/`, and all performance arrays remain tied to their original measured binary. No new performance distribution is claimed for build 27. Its delta is limited to drag preparation/completion and version metadata; the measured storage, show/search/copy and idle paths are unchanged.

Final build 27 regressions: Debug, 92 discovered / 81 passed / 11 conditional skips; Release with named pasteboards, 92 / 86 / 6, no failures. Both include deletion, expiry and empty-history drag completion cases. The pre-fix regression failed eight assertions. The default sandboxed Release suite also passed 81/11; a later named-pasteboard attempt was blocked by the sandbox and terminated with signal 5 (retained failed log). The authorized rerun above permitted temporary named boards and passed. None used the general clipboard. Final production packaging uses these frozen sources; no additional benchmark run is attributed to build 27.

Independent review is a separate read-only implementation/evidence assessment: 0.3.5 follow-up report. It cannot substitute for unobserved physical GUI acceptance.
