# Code-file paste investigation

Project: `/Users/ronny/VscodeProjects/rea`; change directory: `paste-report/implementation-plan-2026-10-10`.

User symptom: copied `.swift` and `.json` files do not become file contents in Zed/VS Code after selecting history with a double-click.

## Investigation

- [x] Read file representation, file reader, persisted setting, double-click dispatch, focus capture, target classifier, and paste coordinator.
- [x] Verify `.swift`/`.json` are supported and the UI dispatches a real direct-paste request. Keep the requested default OFF.
- [x] Observe Zed's actual accessibility tree: editor focused as a standard window, without a text-area role. Its previous classification was always unknown.
- [x] Reproduce the independent focus-timing defect: initial unknown target becomes text when original editor focus returns, but conversion was never retried. `red-focus.log` fails four content/type assertions; corrected implementation passes.
- [x] Check Electron's official accessibility documentation and test `AXManualAccessibility`. The real VS Code probe exposed AXTextArea, but toggling this attribute rebuilt its focused-control identity and triggered a safe fallback. Remove the mutation; retain the existing focused editor metadata.
- [x] Add enabled/disabled `.swift`/`.json` regression coverage with real temporary files and SQLite. Correct test settings/snapshot revisions; do not weaken policy validation.
- [x] Run the full 66-test suite including private macOS pasteboards, quota/no-loss and crash recovery: `regression-native-fix.log` passed, 8.549 seconds.
- [x] Build and verify Release 0.3.1 (22): signed arm64 executable, matching SwiftPM code section, offline syntax resources, no Debug probes. `release-final.log` and `artifacts.json`.
- [x] Verify actual Swift and JSON receipt in VS Code and Zed with the finalized isolated Debug app. Four documents saved through the actual editors match source fixtures byte for byte; screenshots and SHA256 results are retained. The disabled-switch Zed test pastes the original path, matching existing behavior. No TCC modification or user history capture.

## Hypotheses and root cause

| Hypothesis | Evidence and result |
| --- | --- |
| Reader lacks swift/json support | Rejected: extensions are supported; exact-content tests pass. |
| File URL capture/store corrupts content | Rejected for tested inputs: private NSPasteboard/SQLite preserve original references, ordering and bytes. |
| Default-off switch | Expected behavior by specification; not silently enabled or blamed as the sole cause. |
| Editor recognition too narrow | Confirmed for Zed by actual AX window observation and classifier inspection. Text roles alone cannot cover its current custom editor. |
| Focus-time unknown never retried | Confirmed by a failing integration regression using actual files and SQLite, then passing after the fix. |
| Electron delays accessibility exposure | Official API checked. Actual VS Code before/after metadata in vscode-swift-ready.json showed AXTextArea recognized as text, followed by a changed AX identity after enabling its tree. This proposed mutation was removed; no screen-reader-mode toggles remain. |

The requirements are unchanged. These are implementation gaps in target detection and the timing of an existing conversion operation, not a storage/schema problem.

## Fix and scope

`MacApplicationClient.swift`: retain focused-control identity, secure/disabled/read-only checks; recognize only Zed's window-only editor fallback. Do not change Electron accessibility modes while remembering focus. Unknown apps and non-text controls remain file targets/default behavior.

`PasteCoordinator.swift`: when an enabled file group was unknown while the panel held focus, retry classification and reading after the original editor focus is stable. Recheck setting, file identity, history, foreground identity and clipboard receipt before replacing owned file references with complete text. Preserve existing rollback and new-copy protection. Default OFF and Finder behavior remain unchanged.

Tests: `CodeFeaturesTests.swift`, the existing fake application's restoration callback. Debug-only `CodePasteProbe.swift` and main entry provide isolated actual-target tests; they do not appear in Release. Syntax rendering is untouched and remains always on. No migrations or compatibility framework.

Official reference: [Electron accessibility documentation](https://www.electronjs.org/docs/latest/tutorial/accessibility).

## Exit review

Checked root cause coverage, preservation of unrelated work, setting independence, unchanged file storage, new-copy protection, bounded background file work, target identity and unknown-target fallback. Chinese comments explain the focused changes. The retry uses existing reader/composer/receipt contracts rather than introducing a second paste system.

Build: `rtk proxy bash macos-app/scripts/build-app.sh release`.
Regression: `rtk proxy env LOCALCLIP_NAMED_TEST=1 bash macos-app/scripts/test.sh`.
Evidence root: `macos-app/evidence/delivery/code-smart-paste-fix/`. Failed exploratory runs are retained and distinguished from the passing run.

## Actual receipt results — 0.3.1 fix

macOS 15.7.5 (24G624), arm64. Native tests use the frozen Debug bundle with the same production ApplicationClient/PasteCoordinator paths; Release 0.3.1 (22) is built separately and excludes probes. The probe inserts a specified synthetic file URL into a private temporary SQLite store, starts no clipboard capture, checks the expected external foreground app and permission, then invokes the real direct-paste operation. This verifies native target receipt, not the entire history-panel mouse double-click workflow.

| Target | Smart setting | Input | Actual result | Evidence |
| --- | --- | --- | --- | --- |
| VS Code 1.141.0 | ON | Swift | Received exact 77-byte source, including Chinese and final newline | Screenshot, native checks |
| VS Code 1.141.0 | ON | JSON | Received exact 79-byte source, including indentation and final newline | Screenshot, native checks |
| Zed 1.23.2 | ON | Swift | Received exact 77-byte source | Screenshot, native checks |
| Zed 1.23.2 | ON | JSON | Received exact 79-byte source | Screenshot, native checks |
| Zed 1.23.2 | OFF | Swift | Original file path pasted; no conversion, matching existing behavior | Screenshot, native checks |

Exact-byte and hash comparison covers the four saved documents in `fixtures/`. Original fixture files are unchanged. Environment. VS Code retains its existing focused AXTextArea; Zed exposes only AXWindow. Before/after focus identity and actual foreground checks pass for the successful runs.

An extra ordinary Command–V test was not completed: automatic approval initially rejected it because the AX tree could not establish a blank document; a subsequent screenshot established a safe blank tab and permitted a retry, but the native foreground guard then blocked the test. No paste was sent by that attempt (`zed-manual-prepare.json`). Failed permission/focus/exploratory logs remain; they are not counted as successful receipt.

Remaining scope: Safari/Chrome, TextEdit, Finder directory receipt, other IDEs and the full mouse double-click workflow were not rerun in this fix. Zed's window-only accessibility tree cannot provide editor-caret-level focus proof; the fallback is restricted to its bundle and still requires unchanged target/window identity. Unknown apps remain original-file behavior. Performance measurements for the highlighting/reader component are inherited from the preceding feature delivery, not a new cross-app latency measurement.

User setup: the smart setting remains default OFF; turn on 「代码文件智能粘贴」 to use code contents. Accessibility must cover the final `dist/LocalClip.app` binary when launching it; the test-bundle authorization alone is not proof of the Release grant. No compatibility/migration code was added.
