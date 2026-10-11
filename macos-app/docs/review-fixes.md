# LocalClip review fixes — 2026-10-11

Previous delivery: **0.3.4 (25)**, based on `1b9cbed2e956f9ac1c9668c7809243b1a74b975e`. This addresses the [independent review](../../paste-report/review/independent-review-report.md). Implementation, service measurements, rendered components and live Release acceptance are reported separately. Current **0.3.5 (26)** LC-06/drag/focus follow-up: [checks and limits](scaling-drag-focus-checks.md).

## Independent review and follow-up

The [independent 0.3.2 review](../evidence/review-fixes/independent-review-20261011.md) returned **FAIL** with two reproduced findings. Its report and probes remain unchanged; the reviewed application, source archive and manifests are preserved in `evidence/review-fixes/reviewed-0.3.2/`.

- **IR-01:** A selected entry at index 49/99 could shift beyond a 50/100-item loaded window on capture. Refresh now checks prior selection and tail IDs against the current search filters/revision, then reads until surviving anchors are included. Deleted or filtered-out IDs do not force a full-history scan. Regressions cover both boundaries, a 75-copy hidden-panel burst and deletion.
- **IR-02:** The detached worker reopened the current board using old approved declarations, allowing a sensitive body read before rejection. It now receives the approved changeCount, rechecks the worker's current generation and all declarations before any body IPC, checks generation before each representation and after the body, and retains final publication/epoch checks. Fake late-reopen tests cover both sensitive markers; a private native board uses a lazy data provider to verify zero body reads when generation changes.

The [independent 0.3.3 follow-up](../evidence/review-fixes/independent-rereview-20261011.md) confirmed IR-01/IR-02 corrected, but returned **FAIL** for **IR-03**: eight captures expanded 50 loaded rows to 450 without scrolling. That report and reviewed snapshot in `reviewed-0.3.3/` remain unchanged.

**0.3.4** publishes only the precise range needed for the previous window and surviving anchors. When a fetched page contains extra rows, the continuation cursor resumes at the published range's end, so subsequent pagination skips no rows. Each new copy adds only its actual row. A regression uses 80- and 500-entry histories, repeats eight captures, then explicitly loads more and compares the ordered range with independent store pagination. It covers truncation when the final fetched page has no cursor. An initial attempt to retain only a separate logical tail failed the hidden-burst window assertion; its failed log remains recorded and the approach was replaced, preserving the existing tests.

The [final independent review](../evidence/review-fixes/independent-final-review-20261011.md) records its verdict against 0.3.4. Neither earlier FAIL verdict is revised.

## Finding status

| Finding | Change and verification | Status |
|---|---|---|
| LC-01 | Refresh the previously loaded window under one query ID; preserve selected IDs and immutable detail, choose the nearest remaining item on deletion. Maintenance refreshes only after expiry. Hidden panels defer list/source/usage refresh. The 130-item regression retains index-120 selection/detail; exact 50/100-item boundary and hidden-burst regressions retain the surviving original window and detail. Publish the exact required prefix and resume pagination at its end to prevent whole-page growth or skipped rows. | Fixed; live scroll/IME check pending |
| LC-02 | Remove the Zed `AXWindow` exception. Terminal bundles and terminal-labelled AX ancestors remain unknown and cannot trigger code conversion; no AX text body is read. Classifier tables cover native and embedded terminal metadata. | Fixed at classifier boundary; real target matrix pending |
| LC-03 | Quota pressure evicts ordinary history with its index instead of deleting every text index. Large text retains normalized search text while avoiding duplicate derived plaintext. Missing legacy indexes have correct fallback and bounded 200-clip background repair. Quota fixture retains 7,333 text clips and 7,333 index rows. | Fixed |
| LC-04 | Preference refresh preserves queued copies and the observed baseline. Only actual pause/resume, capacity and explicit wake/rebaseline transitions invalidate the capture epoch. Queue and suspended-read regressions verify preservation and deliberate pause rejection. | Fixed |
| LC-05 | Remove the all-text Swift corpus. SQL ranks literal UTF-8 bytes without materializing every source payload in Swift; page results remain bounded. NFC, punctuation, NUL and missing-index regressions pass. Search debounce is 20 ms. | 0.3.4 fixed; 0.3.5 isolated GUI timing measured, search budget missed; see current follow-up |
| LC-06 | Thumbnails use a bounded 16 MiB / 256-entry memory cache without a database commit; slider persistence is coalesced. Quota eviction batches its transaction and limits orphan checks to affected digests. Atomic user-data commit verification, sync and rename remain intact. | 0.3.4 mitigation; 0.3.5 removes routine full-payload verification scans; see current follow-up |
| LC-07 | Backspace/Delete always stay in the native editable search field, including when empty. Record undo is available through Command-Z for an unchanged query and through the menu. | Fixed; native keyboard/IME acceptance pending |
| LC-08 | Smart code conversion requires direct paste. Copy restores original file URLs regardless of the remembered target; named-pasteboard tests verify Copy and direct paste separately. | Fixed |
| LC-09 | Export access uses immutable clip identity/hash plus current existence, visibility and expiry instead of global revision. Unrelated commits retain access; deletion invalidates it. | Fixed; real mouse/receiver check pending |
| LC-10 | Native pasteboard body reads run on a detached utility task with a newly opened board by name. Main-actor source policy precedes reading; the worker separately revalidates current generation, item declarations and sensitive markers before body reads, with generation checks around each representation and before publication. Cancellation and capture epoch guards remain. Private-board tests preserve bytes and item order. | Fixed structurally; large-image IPC timing pending |
| LC-11 | Add common language/config extensions and Makefile/Dockerfile variants; allow formfeed and ESC, still reject NUL/binary controls. Failed code conversion restores originals and displays its reason. | Fixed |
| LC-12 | Detail and card highlighters use separate actors. Detection uses at most 2,048 characters before explicit highlighting of the bounded detail; single-line HTTP(S)/mailto URLs skip detection. | Fixed; full-detail timing not remeasured |
| LC-13 | Correct historical counts and label the 0.3.0 Debug coordinator receipt evidence. Current executed/skipped tests are explicit below. Package signing and service timing do not certify UI receipt or AC16. | Claims corrected; live Release acceptance open |
| LC-14 | Height preview resizes without persistence; gesture/slider end saves the final value. Pending preference edits are serialized and combined instead of dropped. Final-value regression passes. | Fixed |
| LC-15 | Minimum displayed height is 280 pt. Code previews keep indentation and truncate each line without soft wrapping. Toolbar colors follow SwiftUI appearance. New light minimum-height and dark code renders are inspected below. | Fixed component layout; live display check pending |
| LC-16 | Enable and verify SQLite `secure_delete`, keep temporary SQL data in memory. A partially used page regression checks deleted raw/normalized bytes are absent and undo still works. APFS snapshots, backups and physical media are outside this guarantee. | Fixed SQLite residue path |
| LC-17 | Recheck the latest persisted capture policy before ingest; restamp/retry unrelated preference revisions while preserving actual pause, source and sensitive rejection. | Fixed |
| LC-18 | Remove the production `foo_bar` glyph heuristic; use the detector result. Mark historical delivery documents and correct the active Release directory to `LocalClip-LocalEdition`. | Fixed |
| LC-19 | Share one weakly registered drag event monitor and route only to the active card. Finder directory AppleScript runs off the main actor. | Implemented; real drag/Finder responsiveness pending |

## Executed checks

- **0.3.4 Release with private named boards enabled:** 88 discovered, **84 executed passed, 4 performance/system tests skipped**, [log](../evidence/automated/20261011-053007-W2bGa7/swift-test.log). Native worker zero-body-read and exact format tests pass alongside final window/cursor tests.


- **0.3.4 Debug:** 88 discovered, **79 executed passed, 9 skipped**, [log](../evidence/automated/20261011-052939-yLMitU/swift-test.log).


- Historical **0.3.3 Debug:** 87 discovered, **78 executed passed, 9 skipped**, [log](../evidence/automated/20261011-051425-EnujM6/swift-test.log).
- Historical **0.3.3 Release with private named boards enabled:** 87 discovered, **83 executed passed, 4 performance/system tests skipped**, [log](../evidence/automated/20261011-051516-TdnQLE/swift-test.log).
- All five named-board tests pass, including late-generation rejection with **zero lazy-provider body requests**. The two boundary sizes and both marker variants pass their parameterized fake/temporary-SQLite cases. No general pasteboard or production history is accessed.


- Historical 0.3.2 Debug full suite: **82 discovered, 74 executed passed, 8 skipped**, [log](../evidence/automated/20261011-044047-FzNrlE/swift-test.log).
- Historical 0.3.2 Release full suite: **82 discovered, 74 executed passed, 8 skipped**, [log](../evidence/automated/20261011-044322-g8Gkl4/swift-test.log).
- Historical 0.3.2 private named pasteboards: **4 executed passed**, [log](../evidence/automated/20261011-044308-dllFlG/swift-test.log). No general pasteboard writes.
- Historical 0.3.2 Release with named pasteboards enabled: **82 discovered, 78 executed passed, 4 performance/system tests skipped**, [log](../evidence/automated/20261011-044630-UhUlfv/swift-test.log).
- That suite preceded the final glyph-only adjustment. The final glyphs compile and render in both themes; the shipping Release package was rebuilt afterward. The failed symbol render and isolated color probe are retained in `evidence/review-fixes/ui/`.
- The full suites include temporary SQLite, all existing SIGKILL fault points, 500 MiB protected-store refusal, queue/selection preservation, literal search and export cancellation.
- The historical skips are four opt-in real pasteboard cases and four opt-in performance/system cases. The revised suite adds a fifth opt-in named-board privacy test. The new service benchmark is executed separately below. No ten-consecutive-run flake gate is claimed.
- Earlier failed benchmark attempts and obsolete Copy assertions remain in the logs; the corrected assertions verify that Copy preserves files. The first sandboxed private-board attempt could not access the OS service; the scoped retry above passed.
- [Light, 1,400 × 280 pt](../evidence/review-fixes/ui/light-1400-280.png) and [dark code, 1,400 × 340 pt](../evidence/review-fixes/ui/dark-code-1400-340.png) are isolated native SwiftUI renders, not live target acceptance.

## Service performance

Release, `localclip-fixtures-v2`, seed `0xC11F`: 10,000 texts and 100 real generated images. Raw [samples](../evidence/review-fixes/performance-v2/results.json) and [fixture manifest](../evidence/review-fixes/performance-v2/fixture-manifest.json) are retained. P95 uses nearest rank. The normal desktop session was not isolated. Boundary is **HistoryStore call → return**, excluding debounce, polling, decoding and drawing.

| Operation | Samples | New P95 ms | Review P95 ms |
|---|---:|---:|---:|
| Warm literal search | 200 | 56.95 | 32.9 |
| First search after capture | 40 | 56.87 | 121.7 |
| Search after quota pressure and capture | 20 | 45.65 | 1,180.7 |
| Text ingest | 40 | 125.26 | 326.4 |
| Thumbnail cache write | 20 | 0.662 | 112.7 |
| 8 MiB writes at quota | 3 | 384.40 | 543.5 |

Warm search is slower than the previous warm corpus; the cold rebuild and post-quota cliff are removed without retaining that corpus. The final pressure fixture has all 7,333 surviving text clips indexed. The three quota samples are too few for a stable distribution. [First optimization attempt](../evidence/review-fixes/performance-v1/results.json) remains visible: it was slower and led to byte borrowing and batched quota eviction. These measurements belong to 0.3.2. The 0.3.3 follow-up adds restricted query-membership reads to preserve window anchors; refresh overhead and end-to-end timing have not been remeasured. No new memory-footprint or idle-resource acceptance is claimed.

Reproduce into a **new empty output directory**:

```sh
rtk proxy env LOCALCLIP_REVIEW_BENCHMARK=1 LOCALCLIP_REVIEW_OUTPUT=/absolute/path/new-output bash macos-app/scripts/test.sh -c release --filter coldWarmAndPostQuotaSearch
```

## Remaining acceptance

Live Release double-click target receipt, terminal/editor/Finder matrix, real mouse drag, keyboard/IME, multi-display, login/hotkey and input/copy-to-visible timing remain open. The running user app was not restarted or taken over, and production history was not opened. Routine full-payload verification in 0.3.4 is superseded for validated APFS writes by the linked 0.3.5 follow-up; non-APFS backup and quota reclamation can still scale with database size. Existing missing-index stores that cannot fit repair safely keep correct raw-payload search, which can remain slower until space is available.

The packaged app is ad-hoc signed for local testing. Build/version/hash checks are recorded in [0.3.4 artifacts](../evidence/review-fixes/artifacts-0.3.4.json). The 0.3.4 changes were subsequently committed as `87c71a2`; the follow-up preserves the current `.gitignore` baseline.
