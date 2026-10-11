# LocalClip independent-review remediation — 2026-10-11

Request: “fix asap based on the review comments.” Scope: LC-01 through LC-19 at baseline `1b9cbed`; deliver local 0.3.4 (25), retaining reviewed 0.3.2 (23) and 0.3.3 (24) snapshots. [Finding-by-finding outcome](../../../macos-app/docs/review-fixes.md).

## Investigation checklist

- [x] Read the pasted review, source and requirement chain; locate refresh, policy, export, search, atomic commit, paste and UI boundaries.
- [x] Test preservation rather than merely invalidation: 130-item history, queued captures, unrelated export commits and latest preference values.
- [x] Keep existing no-loss commit semantics; run real temporary SQLite, 500 MiB refusal and SIGKILL regressions.
- [x] Verify exact original-file Copy and direct-paste conversion on private named OS pasteboards.
- [x] Measure Release storage service performance with the review fixture generator; retain the slower first attempt.
- [x] Inspect isolated native SwiftUI renders; distinguish them from live application acceptance.
- [x] Build the local Release artifact and reconcile current versus historical evidence.

## Hypotheses and root-cause chain

| Hypothesis / confidence | Check and result | Cause and remedy |
|---|---|---|
| Global invalidation loses browsing/drag state (high) | View model/export regressions exercise unrelated commits, maintenance and deletion | Global revision was used beyond its valid scope. Preserve loaded window and immutable selected content; validate export by clip hash/existence/visibility. |
| Policy refresh loses queued/in-flight copies (high) | Queue and suspended body-read tests preserve A/B/C under preferences but reject genuinely paused captures | Policy assignment also reset the baseline/queue. Separate epoch/rebaseline transitions; recheck current policy at ingest. |
| Quota eviction creates a permanent search cliff (high) | Final pressure fixture has 7,333 surviving text clips and 7,333 index rows; post-pressure search P95 45.65 ms | Whole-index deletion plus full Swift corpus rebuilding. Retain normalized rows, evict ordinary clips consistently, repair old gaps in bounded batches, rank UTF-8 literals in SQL. |
| Derived writes dominate atomic commit cost (high) | Thumbnail regression leaves DB bytes/revision unchanged; service P95 0.662 ms | Thumbnails entered the user-history candidate protocol. Use bounded memory; batch quota work and final slider persistence. Keep primary atomic commits intact; LC-06 is mitigated rather than fully eliminated. |
| Smart paste relies on overly broad target/action classification (high) | Classifier, Copy and private-board tests pass | Any Zed window/terminals and Copy qualified for conversion. Require direct paste and positive non-terminal metadata; preserve files on Copy. |
| SQLite free cells retain deleted text (medium before check) | Partial-page byte scan confirms secure deletion and undo | Enable and verify secure_delete. This covers the current DB, not snapshots/backups/media. |
| Toolbar appearance or symbol rendering overrides color (initially medium) | Fresh source/binary/PNG timestamps excluded a stale artifact; runtime reported `light` and `#474747FF`, while pixels were white. Isolated plain-button symbols honored the same gray. Theme/template modifier changes did not fix the panel. Final explicit vector glyphs render dark gray in light and light gray in dark. | The observed failure is specific to symbol rendering in this panel; the underlying framework cause is not established. Draw the two tiny glyphs explicitly with the intended theme color. Preserve the failed render and isolated probe in `evidence/review-fixes/ui/`. |

## Decisions and verification boundaries

The review and user instruction authorize its concrete behavioral corrections, including Copy preserving files and conservative terminal handling. No adjacent architecture extraction or unsafe storage-protocol rewrite was introduced. Original format, source/privacy checks, pause semantics, receipt/focus checks and no-overwrite Finder behavior remain covered.

Full Debug/Release suites and scoped named-board checks pass with explicit executed/skipped counts in the report. Earlier named-board sandbox failures and obsolete assertion failures remain recorded. One manual build omitted the workspace cache environment and failed on a sandboxed cache path; the normal isolated-cache build resolved it. The first SQL benchmark was slower; byte borrowing and batched eviction yielded the recorded final run.

The final full Release suite preceded the last glyph-only change; the final glyphs were compiled and inspected in both native component renders, then included in the rebuilt Release package. The Debug renderer explicitly supplies its requested appearance for offscreen evidence. The PUA troubleshooting checklist was used to stop repeated modifier changes and isolate the contrast failure.

Live GUI receipt and AC16 end-to-end timing are still unverified. No production app restart, system clipboard write or production history access was performed; the pre-existing `.gitignore` edit was preserved. Same-agent self-check covered cause, redundancy, scope, unnecessary complexity and Chinese fix comments. The initial independent review and subsequent remediation are recorded below. No ten-run flake gate is claimed.


## Independent review follow-up — 0.3.3 (24)

The fresh review agent returned FAIL against unchanged 0.3.2 sources/artifacts. Its initial report, standalone probes and observed JSON remain intact. The exact reviewed package/source archive/manifests are preserved under `macos-app/evidence/review-fixes/reviewed-0.3.2/`.

- IR-01, confidence 100: keeping only the old count lost a valid selected clip shifted beyond index 49/99. Match old tail/selection IDs through the existing search filters at a common revision; load until surviving anchors are reached. A removed/nonmatching ID no longer becomes an unbounded pagination target. Exact 50/100 boundaries, a hidden 75-copy burst, and subsequent deletion have dedicated tests.
- IR-02, confidence 95: late native board reopening used stale approved types. The worker now receives expected changeCount, reads current types before any body, rejects marker/type/generation changes, and checks generation before each representation and after all data. The main-actor final count and capture epoch remain. Both fake marker races assert zero body callbacks; a native private-board lazy provider test checks changed-generation rejection without a body request.

Focused regression run passed all five selected tests (including two parameterized boundaries and two markers). Existing stableRetry now expects one read per attempt: after count changes during the first representation the reader stops before requesting the second. A separate follow-up independent review will judge the rebuilt 0.3.3 snapshot; the initial FAIL verdict is not changed.

Final revised Debug run: 87 discovered, 78 executed passed, 9 opt-in tests skipped (`20261011-051425-EnujM6`). Revised Release with named boards: 87 discovered, 83 executed passed, 4 performance/system skips (`20261011-051516-TdnQLE`). Native late-generation provider received zero body requests; current private-board sensitive filtering and unchanged full-format reads passed.


## Independent IR-03 follow-up — 0.3.4 (25)

The 0.3.3 independent follow-up confirmed IR-01/IR-02 corrected, but reproduced page amplification: 50 initial rows became 450 after eight single captures, without pagination or scrolling. Its FAIL report and exact reviewed app/archive/manifests remain preserved.

The first narrow attempt retained a separate logical tail established by explicit pagination. It passed the growth test but failed both hidden-burst assertions because the previously published extra rows could leave the window. The failed focused run is retained (`20261011-052712-Rzcvdy`, see automated logs); the existing preservation assertions were not weakened.

The final correction trims fetched padding before publishing and rewinds a same-revision/signature cursor to the exact published offset. This preserves every surviving prior-window row/selected anchor while preventing page rounding from becoming new window demand. Subsequent explicit loadMore reads all trimmed rows in order. An 80/500-entry/eight-copy regression checks exact row growth, selection preservation and equality with independently paginated store IDs before and after explicit pagination, including the no-next-cursor final-page case.

Final 0.3.4 Debug suite: 88 discovered, 79 executed passed, 9 opt-in skips (`20261011-052939-yLMitU`). Both history sizes and both hidden-boundary cases pass; their expected previous-window ranges are preserved.

Final 0.3.4 Release named-enabled suite: 88 discovered, 84 executed passed, 4 performance/system skips (`20261011-053007-W2bGa7`). Both 80/500-entry exact-growth cases, 50/100 boundaries, hidden bursts, native sensitive-before-body guard and full representation reads pass.
