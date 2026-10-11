# LocalClip 0.3.7 (29): shared category-drop routing

The user reported that dropping into the newly created “提示词” category still failed in the prior delivery, for text as well as images. This is a shared drop-path issue. The previous text test invoked the receiver helpers directly; it did not establish that AppKit delivered a drop to the category embedded in the SwiftUI panel.

## Change

The production history panel now uses `CategoryDropHostingView`, a small `NSHostingView` subclass. Both the hosting boundary and the individual category button register the internal category type. The hosting destination handles the native enter/update/prepare/perform/conclude/end callbacks and routes to the actual category button under `sender.draggingLocation`.

The route uses destination-window identity, button bounds and visible clipping, the current model identity, and the existing short-lived token validation. It claims the token synchronously and submits the same ID-based category operation as the button. Only one destination can claim it; the route preserves existing memberships and does not copy clipboard payloads. The native source-end callback does not assign membership, so ending/cancelling over a category is not treated as a successful drop.

The route is independent of public payload kind: text, URL, RTF, HTML, PNG, TIFF, JPEG, file references, mixed records and multi-selection use the same internal identity. Public export writers, capture, storage, search, progressive loading and selection policies are unchanged from build 28. Pointer position determines the target; a large drag image merely overlapping a label does not qualify. Both destinations clear their hover feedback on cancellation, including an end without an exit callback.

## Evidence and limits

The corrected invisible full-panel probe reaches the real `CategoryButton`, whose type registration is intact. Its earlier failing probe passed the wrong flipped coordinates into `hitTest`; that failure is retained and is not evidence of a SwiftUI interception defect. The exact original callback-delivery or rejection mechanism is not proven from the available evidence.

`CategoryDropRoutingTests` mounts the real `HistoryView` in an invisible nonactivating AppKit panel, creates “提示词” after mounting, and then invokes the production hosting destination through a synthetic `NSDraggingInfo`. Real export writers and temporary named pasteboards carry all eight supported representations and a mixed record into temporary SQLite. A fresh second category proves that exactly the selected records gain membership while others remain absent. Tests also check registration after live model/drag changes, hidden/outside/wrong-window targets, replay/forgery, cancellation without exit, and unchanged persistence revision after rejection.

This is broader receiver/routing evidence than the earlier helper-only test. It does not simulate a physical native dragging session or prove OS callback delivery, animation or perceived GUI behavior. The user explicitly owns live GUI testing. This turn does not launch/install the production app, access general clipboard/history data, or change permissions.

Final Debug: 101 discovered, 86 passed, 15 conditional skips, no failures ([log](../evidence/automated/20261011-160751-5pW7Cl/swift-test.log)). Final Release with named pasteboards enabled: 101 discovered, 94 passed, 7 conditional skips, no failures ([log](../evidence/automated/20261011-160754-qSUnIl/swift-test.log)); both new routed-destination tests executed and passed. The retained capture, output, loading, quota and crash regressions also pass. Long opt-in benchmarks were skipped; no fresh GUI/performance measurement is claimed for this routing-only change.

Prior build 28 app/archive/manifest are preserved in `evidence/review-fixes/category-drop-routing-20261011/baseline-build28/`. Current artifact hashes are in [artifacts-0.3.7.json](../evidence/review-fixes/category-drop-routing-20261011/artifacts-0.3.7.json); the independent final report is [here](../evidence/review-fixes/independent-category-drop-routing-review-20261011.md).
