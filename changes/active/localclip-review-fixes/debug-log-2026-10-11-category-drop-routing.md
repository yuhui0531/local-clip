# Shared category-drop routing — 2026-10-11

Project root: `/Users/ronny/VscodeProjects/rea`.
Change directory: `/Users/ronny/VscodeProjects/rea/changes/active/localclip-review-fixes`.
User anchor: actual drop into the newly created “提示词” category still fails; text has the same failure, and all supported kinds must work. The earlier user instruction keeps live GUI testing with the user.

## Investigation

- [x] Trace public writers, native source lifecycle, category token gates and destination registration. Both text and image providers eagerly publish the same token; there is no supported image-specific defect.
- [x] Identify the previous evidence gap: a direct call to an unattached receiver does not verify native framework delivery through the hosted panel.
- [x] Mount the actual HistoryView in an invisible nonactivating panel. Correct the probe's flipped-coordinate mistake: hitTest expects superview coordinates. The corrected probe reaches the registered CategoryButton; do not infer interception from the initial failed probe.
- [x] Preserve the validation/persistence contract and implement a shared hosting-boundary destination route using actual pointer/window/clipping coordinates. No source-end membership fallback, no public-format rewrite, no schema/storage change.
- [x] Verify all representations, new categories after mount and fresh-category multi-selection through real writers/named boards/SQLite with synthetic native destination callbacks.
- [x] Address independent feedback: draggingEnded clears cancellation highlight for both host and button; assert type registration after model/drag updates and reject wrong destination windows.

## Cause and scope

The user's report establishes the shared physical failure. The exact original callback-delivery/rejection mechanism remains unproven without a live native trace. Build 28 had only an embedded button destination and helper-level persistence tests; build 29 adds a panel hosting destination sharing the same one-time token claim, plus routed callback tests. The repair covers the missing receiver boundary without changing payload handling or weakening cancellation/identity checks.

The drag image is not the target: the route uses draggingLocation and the button's actual visible bounds. Membership is committed only through performDragOperation; draggingEnded only clears feedback.

## Verification

The focused all-kind route passed after the new-category/multi-selection changes (`20261011-160535-2PyOsQ`) and after cancellation cleanup (`20261011-160636-76QsCL`), two tests each. The earlier protocol compile error (`20261011-160306-u8Td7Z`) and incorrect-coordinate probe failure (`20261011-155623-GQyKAu`) remain preserved. Final full Debug/Release logs and hashes are recorded in the delivery document/manifest.

Exit review: narrow host/button/AppDelegate change; shared ID operation, pointer coordinates and token security preserved; all supported kinds covered; no compatibility layer or unrelated feature change. Existing storage/capture/output/loading regressions run again. No actual GUI smoothness or physical drop success is claimed from synthetic callbacks. Build 0.3.7 (29) is prepared locally; the user will test the new app.
