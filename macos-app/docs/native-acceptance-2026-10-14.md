# LocalClip acceptance follow-up — 2026-10-14

**Acceptance remains incomplete. No waiver, installation, or publication.** Desktop automation stopped at the user's instruction. Subsequent work consists only of source changes, headless tests, compilation, and file-based evidence checks.

## Authority and candidate identity

- Full report read: `macos-app/docs/reviews/LocalClip_Review_c097591_2026-10-14.md`, **LocalClip 全面代码与产品体验 Review 报告**, including all LC-001–LC-021 details, acceptance criteria, UX/UI, performance plan and implementation roadmap (885 lines).
- Review SHA: `c097591431c00982ad34186068064b40965c95fd`; current HEAD: `04928517bb964646b73e1de0d48c7828214b5eb2`. No reset to the review SHA.
- [Per-finding disposition and earlier measurements](review-remediation-c097591.md) remain applicable with the updates below. Earlier test runs do not certify the later source revision.
- Native evidence root: `macos-app/evidence/native-acceptance-20261014/` (local, ignored). This directory must accompany a handoff; the Markdown alone does not contain the raw evidence.
- Native tests used a frozen 150-file source snapshot in `candidate-source/macos-app`, recorded in `candidate-source-sha256.json`. All 150 hashes were rechecked successfully after testing.
- Native executable SHA-256: `702ee1f8cc6452d3fa26b2a570663eda9b5770f581940473e49a2ccefc4a2cec`. This was an optimized DEBUG GUI-check bundle (`local.localclip.gui-check`), using the product services/views but regular app activation and test telemetry. It was not installed and is not the production accessory-app acceptance candidate.
- `session-baseline.json` records an earlier working-tree diff hash (`4b9cb673c7da2ae8a42d6c1ff0a38b80f3698a0e092548f7894853c5a600ec6e`). A concurrent capture edit interrupted the first build. The later frozen candidate patch hash is `203fc5743926aaa0f67a306e0968b6530df51ecfb61d91e14494f58d379483a8`. These are different observations, preserved rather than relabeled. The per-file manifest identifies the native-tested source.
- The current keyboard changes were made **after** the native session. Native results below cannot certify those changes; current-source evidence is recorded separately.

## Native observations obtained before desktop automation stopped

Only four synthetic records were used: Unicode/multiline text, styled RTF, image, and file reference. Capture was paused for seven days and automatic updates disabled in this isolated store. Explicit output used the system clipboard. No production history store was examined or modified.

| Scenario | Observed result and evidence | Acceptance boundary |
|---|---|---|
| Plain-text receipt | TextEdit received the exact Unicode/multiline text; `plain-receipt.ax.txt`. | LocalClip **Copy**, then target application's manual Cmd-V. Direct paste was not exercised. |
| Rich-text receipt | TextEdit received the expected text with red, bold, 22-point styling; `rich-receipt.ax.txt` and PNG. | Same Copy/manual-paste route; not every rich-text representation or target. |
| Image receipt | TextEdit displayed the image and saved it in `image-received.rtfd`; `image-receipt.ax.txt` and PNG. Saved PNG equals the original 35,177 bytes, SHA-256 `2fe0d6d4140733168a01652eee62a19db8d6baa9593c75116b4789e69b167584`. | Same Copy/manual-paste route. Byte equality is for this saved PNG. |
| File receipt | Finder paste created `finder-received/LC-NATIVE-FILE.txt`; before/after AX snapshots. File equals the original 50 bytes, SHA-256 `416df95225e9881810d9f990e21a78c0acb7663251347f3d0179a3a21bc9e887`. | Original-format Copy/manual-paste; no physical drag or direct-paste receipt claim. |
| Vision OCR normal completion | TextEdit received the recognized synthetic image text; `ocr-receipt.ax.txt`. | Normal completion only; recognition finished too quickly to establish a native overlap race. |
| Hidden main content | Body absent in visible cards and AX snapshot; `hidden.ax.txt`, PNG. Hidden mouse Detail and results-focused Space did not expose content; `hidden-space.ax.txt`. | `hidden-command-i.ax.txt` had search focus, so it does not prove results-focused Cmd-I handling. |
| Detail lifecycle | Restoring visibility enabled image detail; hiding again removed the open detail; `visible-detail-restored.ax.txt`, `hidden-closes-detail.ax.txt`. | Does not establish delayed file Quick Look or all-window privacy behavior. |
| Copy while hidden | Hidden plain-text Copy/manual-paste produced the exact text; `hidden-plain-copy-receipt.ax.txt`. | `hidden-copy-receipt.ax.txt` is only an RTFD conversion alert, **not** image receipt. That alert was cancelled. |
| File preview | Visible-file Space displayed the correct native file preview; `file-preview-visible.ax.txt`, PNG. | Hidden-file and delayed callback cases remain open. |
| Basic keyboard and rename | Tab/Shift-Tab moved between search/window; first search Return entered results. Rename draft followed by Escape left the original title unchanged; focus/rename AX files. | These partial routes do not establish complete keyboard accessibility. |
| Full Keyboard Access | **Failed on the frozen candidate:** forward Tab cycled through search/window/boards without reaching footer controls. Reverse traversal reached More; Space opened the selected file preview instead of More. | `full-keyboard-tab-traversal.json`, `full-keyboard-shift-tab-traversal.json`, `full-keyboard-more-space.ax.txt`. LC-010 is not accepted. |

`receipt-byte-comparison.json` records the two byte comparisons. `post-native-integrity.json` records read-only SQLite `quick_check=ok`, four unchanged record identities, and canonical hashes recomputed from every stored representation matching the initial fingerprints. Titles remained null after rename cancellation. Copy counts/order changed normally; the database is not claimed byte-identical. Capture remained paused and automatic updates disabled at this check.

## Follow-up implementation and headless verification

The LC-010 failure exposed two interception paths. SearchField now leaves Tab and Shift-Tab to native focus routing, while Return retains the two-stage search/results behavior. The panel monitor leaves unmodified/Shift activation and navigation keys to a focused control, so Space/Return/arrows/Delete do not act on selected history while a control owns focus. Results-panel navigation and application shortcuts remain routed as before. Escape closes open detail before dismissing history. These changes require native retesting of the actual SwiftUI controls and focus chain.

`NonInteractiveAcceptanceTests` exercises in-memory search/editor delegation, marked-text protection and focused-control routing without presenting windows or dispatching input. Deterministic OCR tests now wait for actual task completion, including expiry, persisted hiding and superseding requests completed in either order. Existing hide/delete/new-copy/normal-completion regressions also await completion rather than a fixed sleep. Fake application and clipboard clients are used; headless tests are not real IME, speech, or target-app receipt evidence.

| Fresh run under `macos-app/evidence/automated/` | Result | Scope |
|---|---|---|
| `20261014-140621-qcst0j` | 88 passed functions, 2 failed, 9 skipped | Initial restricted run: two image/file-kind functions failed while macOS type metadata XPC services were unavailable. Preserved, not counted as successful. |
| `20261014-140724-EVSYeV` | **90 passed, 0 failed, 9 gated skips** | Exact same source/filter rerun with service access: core storage/search/deletion, new keyboard/OCR tests, prior OCR, output rejection, file identity checks. No UI automation. |
| `20261014-141110-QtovGS` | **46 passed, 0 failed, 2 gated skips** | Queue order/stop/replacement/retry/hotkeys, transformed output, smart paste and source-file changes, capture privacy/races, update download/cancellation/signature/rollback safety. Fake clients and temporary stores/files; no network download or app installation. |

Counts are test functions; parameterized cases are in the raw logs. Gated tests remain skipped, even where Swift Testing prints a suite-level success. Earlier default, rendering, protocol and performance runs are retained in the remediation report; none is presented as a fresh full-suite run after the keyboard change.

Current Release compilation also passed: `swift build --package-path macos-app --configuration release --disable-sandbox`, exit 0, 42.60 seconds. No resulting executable was launched or installed. `headless-followup-source-sha256.json` records the current source/test hashes and run identifiers. `git diff --check` passed.

Independent source/evidence review found no additional confirmed defect in these narrow changes. It specifically retained two limits: constructed AppKit responders do not prove the actual SwiftUI/FKA responder identity, and the OCR tests do not control deletion between the separate metadata and settings awaits. The latter is an untested interleaving, not a reproduced failure or a passed race test.

## Open acceptance cases and specific blockers

All following entries remain **unaccepted**, not waived. Desktop-dependent work cannot continue under the user's current restriction.

| Finding / scenario | Concrete missing evidence or blocker |
|---|---|
| LC-001 deletion dialogs | Headless count/size/stale-token coverage exists; real confirmation focus, cancellation and keyboard behavior have not been walked through. |
| LC-002 hidden contents | Results-focused Cmd-I, hidden file preview, delayed Quick Look completion, all owned windows and actual spoken output remain untested. The recorded Cmd-I attempt had search focus. |
| LC-007 native OCR races | Native recognition completed before a controlled hide/delete/new-copy overlap could be established. Deterministic headless races pass but do not close native timing acceptance. |
| LC-008/009 queue and shortcuts | Fake-client order/retry/conflict cases pass; actual target receipt across queue steps, physical conflicts and alternate keyboard layouts remain untested. |
| LC-010 Full Keyboard Access | Real failure recorded above. Source fix and delegate/helper tests pass, but physical forward/reverse traversal, More activation and shortcut behavior after the fix have not been retested. |
| LC-010 IME | Ctrl-Space followed by typing produced literal `ni`; no marked text/candidate UI was established. In-memory marked-text tests do not prove real composition, selection, Return or Escape behavior. |
| LC-002/010 VoiceOver | VoiceOver could be enabled, but tutorial behavior interrupted initial attempts. Access to `ScreenReaderUIServer` was rejected with “Computer Use was not approved to use ScreenReaderUIServer”. No speech/caption traversal evidence was obtained. Later user prohibition stops further desktop access. |
| LC-011 direct target receipt | Foreground target identity intermittently referred to another application or was invalid while the test interacted with TextEdit. No direct-paste command was sent to an unintended target. Copy/manual-paste receipt is established only for the four cases above; direct paste remains open. |
| Physical drag/drop | No controlled cross-window pointer route to the target was established with the available window-bound automation. No physical drop receipt was obtained; desktop automation is now prohibited. |
| LC-012 settings round trip | Earlier native window assertions exist, but permission round trip with an unsaved draft remains untested. |
| LC-015 file freshness | Local rewrite/replacement/deletion identity tests pass. Slow/disconnected storage and real preview mutation during loading lack a controlled fixture/native run. |
| LC-004/006/016 performance | Earlier 5k Release storage and 52 MiB rejection samples are limited evidence. Large rich-text/mixed-output daemon memory, 100k concurrent-capture load, slow storage, slow AX and real first-frame p50/p95 were not measured. Headless checks cannot establish GUI/daemon latency. |
| LC-017/report UX matrix | Narrow-width/loading/failure/hidden hosted coverage and this native session are partial. Full filter/multiselect/permission/keyboard/VoiceOver matrix, supported OS/Xcode matrix, B01–B09 and 2–8 hour soak remain unrun; no dedicated interactive runner is provisioned. |
| Update/release acceptance | Synthetic updater safety checks pass. Real installer permission/failure/receipt/rollback and tag asset/signature verification were not run. User explicitly says not to publish. |

An intermittent LocalClip AX timeout recovered during the earlier session; fresh telemetry continued while the panel was hidden. It is not established as a product hang or a permanent blocker.

## Desktop state when testing stopped

Full Keyboard Access was restored to its original **off** state, with `full-keyboard-access-restored.ax.txt` evidence. VoiceOver was last observed **on**. Its “show welcome on startup” option was temporarily unchecked; caption-panel preference was already checked and was not changed. VoiceOver/welcome restoration was interrupted by the user stop instruction and is **not verified**. Input-source restoration is also not established. No further desktop or preference operations were attempted through another mechanism. Synthetic app/windows/documents may remain open; cleanup is not claimed.

No native acceptance record or waiver was written. No commit, push, tag, installation or publication was performed. Current automated success does not close the remaining native gates.
