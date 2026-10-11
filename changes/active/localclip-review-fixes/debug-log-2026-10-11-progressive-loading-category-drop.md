# Category drop and progressive loading follow-up — 2026-10-11

Project root: `/Users/ronny/VscodeProjects/rea`.
Change directory: `/Users/ronny/VscodeProjects/rea/changes/active/localclip-review-fixes`.
User anchor: implement the still-broken history-to-custom-category drag, improve the supplied confirmation dialog, explain per-write cloning/scanning, and evaluate then implement progressive loading if beneficial. The user will test the live GUI personally.

## Investigation and hypotheses

- [x] Read the drag bridge, export writers and category destination. High-confidence logic fault: the local mouse monitor swallowed events needed by an already active native drag. The token was also promised despite being immediately available.
- [x] Trace store paging and model/view lifetimes. The ordered summary API and lazy strip already support incremental loading; fixed 50-row initial queries and appearance-triggered fetching loaded more than the viewport needed. The issue is loading policy, not a missing storage abstraction.
- [x] Inspect candidate commit validation. The candidate protects the original against failed writes/quota checks; APFS clone shares blocks. Prior LC-06 changes already removed repeated full-payload validation on trusted clones. Retained metadata/quota work is not constant-time.
- [x] Inspect the generic alert and preview contract. Replace presentation/copy while retaining explicit approval and stale-preview validation. Do not bypass confirmation when affectedCount is zero.

## Root causes and changes

1. Before the native session, the bridge still owns threshold/hit/selection behavior. Once native dragging starts, return drag/up events unchanged and let AppKit's ended callback clean up. Write the internal token eagerly; validate and claim it through the real category target before persisted assignment.
2. Calculate the initial summary count from viewport/card geometry before querying. Prefetch two viewports within one viewport of the end, with one paging task and query-generation guards. Replace ordinary per-page counting with a one-extra-row check. Reuse existing cursors and stable record IDs.
3. Preserve the first visible ID and relative offset across refresh; decode/release images according to actual visibility. Retain visited summaries for selection and backward browsing instead of adding a second paging cache.
4. Use a compact native sheet with operation-specific wording, impact and buttons, safe one-time cancellation/acceptance, and a focus-dismissal guard.

## Review corrections and regression evidence

The first independent incremental review found two P2 defects: End could overlap prefetch and append duplicate pages, and increasing viewport capacity during a query could leave it underfilled. Both are corrected, with real model/SQLite regressions for repeated End/Select All and resize during initial/prefetch queries. The reviewer also raised scroll restoration when an earlier record changes while the first loaded ID survives; restoration now compares the anchor's computed pixel position, with an insertion/deletion regression.

The first resize regression exposed another timing error: choosing the prefetch size inside its Task let a later resize inflate the request and load 59 rows instead of the required 31. Capture request size at dispatch and fill only the missing capacity. The failed log is preserved at `macos-app/evidence/automated/20261011-151614-g8fRYo/swift-test.log`; the corrected focused run is `20261011-151739-GBcoM6` (7 discovered, 5 passed, 2 conditional skips). Earlier pre-correction full-suite logs remain historical evidence.

Final full-suite logs, current-code loading measurements and artifact hashes are referenced in `macos-app/docs/progressive-history-loading.md` and the external `artifacts-0.3.6.json` manifest. The final independent report retains its own verdict and confidence-labelled findings.

## Exit checks

- [x] Fix the native event ownership and page task ownership directly, preserving format export, category membership and cursor contracts.
- [x] Limit changes to the requested loading/drag/dialog behavior; no schema change, in-place commit switch, new provider or compatibility layer.
- [x] Preserve existing selection/detail, category ordering, search/reset, keyboard paging, End/Select All and failure behavior in regression coverage.
- [x] Keep Chinese code comments explaining the changed ownership/validation paths; no unrelated source edits.
- [x] Separate service timing and named-board persistence from actual GUI draw/input/target receipt. User-run GUI testing is intentional, not reported as an automated pass.

Build 0.3.6 (28) is prepared locally. No production app process, permission setting, general clipboard or user history is operated in this follow-up.
