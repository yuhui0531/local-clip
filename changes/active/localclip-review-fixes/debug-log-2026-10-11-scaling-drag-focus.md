# LC-06, drag identity and panel focus follow-up

Request: fix remaining LC-06; complete live GUI/performance checks; independently review again. Drag should keep its source selection, show animation, and the panel should close when focus leaves.

Baseline: `87c71a2`; production 0.3.4 artifacts preserved under `macos-app/evidence/review-fixes/reviewed-0.3.4`. No production history or general clipboard is used by the test harness.

- [x] Read CommitStrategy, SQLite constraints, HistoryStore mutation/GC/quota/recovery paths.
- [x] Read card gesture/drag event ownership and nonactivating-panel lifecycle.
- [x] Diagnose and implement targeted fixes.
- [x] Restore actual candidate permission failure and NULL-orphan cleanup safeguards after regression failures.
- [x] Run Debug/Release regressions and four-size Release storage scaling.
- [x] Drive isolated native GUI; complete all GUI timing groups and 120 idle samples. Physical drag animation/drop and external focus dismissal remain tool-blocked/unverified.
- [x] Repackage and freeze evidence for the read-only independent follow-up.

| Hypothesis | Confidence and evidence | Cause / fix |
|---|---|---|
| Full candidate reads dominate small writes | High. Previous protocol prefetches every byte and then scans quick_check/FKs after every mutation. 10/100/226/481 MiB inserts now P95 10.89/12.40/15.19/18.27 ms. | Full integrity is a startup/recovery checkpoint. Verified APFS COW clones use SQLite's enabled FK/CHECK constraints, actual quota measurement, FULL journal commit, fsync/F_FULLFSYNC, atomic rename, directory sync and revision/operation reopening. Initialization, untrusted candidates and non-APFS backup retain full checks. |
| GC still scales with all metadata | High, source-level. Ordinary mutations query every blob even without a deletion. | TEMP delete trigger captures only removed representation digests; GC checks their remaining references. NULL-orphans use an indexed lookup. Quota retains affected-digest cleanup. |
| Selection changes because two event recognizers own one drag | High, source and isolated native event evidence. Every unclipped bridge reported the full viewport as visibleRect, allowing an arbitrary card to claim a click. The old monitor also passed down/up into SwiftUI taps. | Intersect bounds and visibleRect, with an explicit card-sized bridge. One native monitor claims down/drag/up; freezes ID/modifiers and selection. Async completion verifies the same down event and held button; selection stays locked through completion. The second card now selects benchmark-9998 and retains that ID during preparation/cancellation. |
| Generic drag icon hides visual continuity | High, source-level. A 48px clipboard symbol replaces the card. | Snapshot actual card; lift/fade source using Reduce Motion-aware spring; native pile and cancel-return animation. |
| Same external app receives a click without activation notification | High, native nonactivating-panel lifecycle. Resign-key/activation checks alone miss that path. | Observe external mouse-down events without interception/key monitoring or permission expansion. Defer dismissal through drag/menu/modal interactions, then recheck. |

Self-check: fixes stay in storage commit/GC, card gesture ownership and focus lifecycle. No journal fast path, schema migration, networking or permission mutation. The GUI harness is DEBUG-only, runs optimized with a separate bundle ID and named board, and is excluded from production Release behavior. Tests, native GUI receipt and service/GUI timings remain distinct evidence classes.

Invalid runs are retained: the first GC test exposed missed NULL cleanup; the old permission regression exposed removal of its early permission check. One build was invalidated by source edits and another by a filename change during compilation. Frozen reruns pass; these failures are not presented as successful evidence.

Final evidence: 0.3.5 (26), Release 85 passed/6 skipped and Debug 80 passed/11 skipped (91 discovered each). GUI P95 warm-open/search/text/image = 152.846/280.553/416.235/618.135 ms. Open/search/image budgets are missed in the isolated optimized DEBUG host. Ten cold-launch samples and all slow outliers are retained. Idle: 120 samples over 605.863 s, CPU mean/P95 0.618/1.896% of one core; sampled RSS max 167.391 MiB. Stress saved 100/100 at 1000/500 ms, 89 at 200 ms and 27 at 50 ms; overwritten changes are reported. Final isolated store integrity/FK and all 20 PNG references pass. No whole-product or physical Release GUI acceptance is claimed.

Independent build 26 review returned FAIL for IR-04: removing the selected source during a drag left selectedID/detail stale. Three regression cases reproduced all eight assertions before repair. Build 27 snapshots visible ID order at drag preparation and reconciles selection only after releasing the lock: preserve a surviving source; choose its nearest surviving neighbor; clear state for empty history. Build 26 artifacts and its FAIL report are preserved. Existing performance samples stay attributed to build 26, with no new performance claim for build 27.

Final build 27 regressions pass: Debug 81/11 and Release with temporary named pasteboards 86/6 (92 discovered each), including all three removal cases. Logs: `20261011-145012-YoZM2N` and `20261011-145453-PgvVJC`. The default sandboxed Release suite passed 81/11 (`20261011-145012-fYwEiF`). A subsequent sandboxed named-board attempt (`20261011-145435-EOBaGp`) failed native writes and exited with signal 5; its log remains retained. The authorized native-board rerun passed without general clipboard or production history access. Final artifacts are frozen for another read-only independent review.
