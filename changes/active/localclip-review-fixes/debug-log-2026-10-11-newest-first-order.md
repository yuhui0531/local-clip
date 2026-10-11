# LocalClip 0.3.8 (30): newest-first category ordering

Project root: `/Users/ronny/VscodeProjects/rea`.
Change directory: `/Users/ronny/VscodeProjects/rea/changes/active/localclip-review-fixes`.

User request: “最新拖动的内容，最新复制的内容，应该排在最左，而不是排到最后，需处理一下。”

## Diagnosis and completed checks

- [x] Read category insertion, browsing order, ingest deduplication, manual movement, deletion undo and progressive-loading contracts.
- [x] Confirm the first hypothesis: single-category browsing sorts `clip_categories.position` ascending, while additions previously assigned `MAX(position)+1`, placing the newest drop last.
- [x] Confirm the second hypothesis: valid external recopy updates `lastCopiedAtMs` but previously leaves category positions unchanged. Ordinary history already sorts newest copy first.
- [x] Confirm the batch-order issue: iterating `Set(ids)` loses the source order of multi-selection.
- [x] Run two production SQLite regressions before repair: both fail with twelve assertions ([baseline log](../../../macos-app/evidence/automated/20261011-203430-Bp5a8d/swift-test.log)). Both pass after the initial correction.
- [x] Address independent review's undo edge case: a deleted head position could be reused by a subsequent drop and tie when restored. The regression fails three assertions before correction ([log](../../../macos-app/evidence/automated/20261011-203823-6RGgRR/swift-test.log)), including a deterministic distinct-position check. All three focused tests then pass ([log](../../../macos-app/evidence/automated/20261011-203900-OsFzca/swift-test.log)).
- [x] Run final full Debug and Release regressions on the frozen source, preserving existing paging, selection, capture, export, privacy, retention, quota and crash checks.

## Implementation

The ordering fix changes only `HistoryStore.swift` production behavior. An ordered, deduplicated batch receives consecutive positions below the existing category minimum. UPSERT also promotes already assigned items when dropped again. Untouched memberships retain their relative order. The allocation reserves positions in the same category's unexpired, existing undo packet so restoring a deleted head cannot tie with a newer drop. No database migration or full-category rewrite is introduced.

Valid external recopy promotes the existing ID in each assigned category inside the same candidate commit that updates its existing copy metadata. Drag/category assignment does not change copy timestamps or counts. Multi-selection keeps its left-to-right source order, existing memberships survive, manual movement continues to work, and removal does not reorder the remaining members.

The category-position rule applies to empty-query, single-category browsing. Ordinary history retains newest valid copy first; combined-category browsing retains copy-time order; nonempty searches retain relevance ranking. App-owned restoration continues to suppress recapture and does not reset retention. The shared ID-based category path applies independently of clipboard payload kind.

## Verification and delivery boundary

Final Debug: **104 discovered, 89 passed, 15 conditional skips, no failures** ([log](../../../macos-app/evidence/automated/20261011-204631-mOXZfc/swift-test.log)). Final Release with named boards: **104 discovered, 97 passed, 7 conditional skips, no failures** ([log](../../../macos-app/evidence/automated/20261011-204725-1xgcEW/swift-test.log)). All three new ordering tests and the existing all-kind hosted destination tests executed in Release.

`CategoryOrderTests` checks newest batches, ordered duplicate handling, re-dropping an existing member, external recopy across every assigned category, unchanged drop copy metadata, cursor invalidation, multi-page order, manual movement, removal, undo position uniqueness and reopening persistence. Existing model regressions retain scroll/selection checks. Long opt-in performance benchmarks remain skipped; this change makes no new performance or physical GUI claim.

Independent source re-review found no remaining actionable issue after the undo correction. The final artifact manifest and combined review are outside the source archive: [manifest](../../../macos-app/evidence/review-fixes/newest-first-order-20261011/artifacts-0.3.8.json), [review](../../../macos-app/evidence/review-fixes/independent-newest-first-order-review-20261011.md).

A concurrent CI compatibility change replaced the export view's `isolated deinit` with `MainActor.assumeIsolated`. Final full regressions were rerun with that change. Subsequent edits to the export callback continued during packaging and invalidated the workspace build; they are left intact in the working checkout. Delivery therefore uses an isolated snapshot of the exact 87 reviewed and tested frozen inputs. The verified export writer is recovered from commit `869b8d3406bc219bf33386333f7f523b0dc48774`, SHA256 `dcba3677c0f0447932f1579f50164e7ae43c7429d155ba9df0fa3bc2ab00e14a`; the isolated-snapshot record identifies it. The source archive and app reflect this verified snapshot, not the later in-flight CI callback edits. Local verification uses Swift 6.2.4; Swift 6.0 compilation itself is not claimed. Earlier passing logs and their input snapshot remain preserved separately.

Build 29 app/archive/manifest are preserved in `macos-app/evidence/review-fixes/newest-first-order-20261011/baseline-build29/`. Build 30 is packaged locally; quit the existing app and open `macos-app/dist/LocalClip-0.3.8-build30.app` to use it. No production app was launched or stopped, no user clipboard/history was accessed, and no permissions or network state were changed. Live GUI testing remains with the user.
