# Native release evidence (LC-017 / LC-020)

Default tests, dedicated pasteboard protocols, native target receipt, GUI/accessibility and performance are separate evidence levels.

The build job has `contents: read`, runs default tests plus the dedicated named-pasteboard matrix, and uploads full logs, environment and machine-readable passed/failed/skipped function lists. Each summary includes the source conditions for gated tests. Skipped functions are not passes. The protocol matrix uses temporary stores and named pasteboards, not the daily clipboard or history.

The tag-only release job downloads the checked build artifacts, verifies checksums and signs the exact packaged application. Only that job has `contents: write` and access to the signing key. Existing version equality, duplicate-release rejection and signature failure checks remain. The three official actions are pinned to commits resolved from their official v4 tag references on 2026-10-14 (raw provenance: `evidence/review-c097591/action-pins.json`). Before each release candidate, review upstream release notes and security advisories, resolve the chosen maintained tag to its commit, and update the pins in a dedicated change with a workflow run. A moved tag never updates a pin automatically.

## Required release record

Before a tag release, a maintainer must set the repository variable `LOCALCLIP_NATIVE_ACCEPTANCE` to a JSON record with:

- `sha`: the exact release commit SHA;
- `disposition`: `passed` or `waived`;
- `reviewer`: the person responsible for the decision;
- `evidence`: traceable native results, or the explicit waiver reason and outstanding scope.

The gate rejects missing, malformed, stale-SHA or incomplete records. There is no default waiver. A recorded waiver is displayed as a waiver in the job summary and never converted into a test pass. It must cover the native GUI/permission and performance gaps listed below. No such repository variable or waiver has been created by this remediation.

## Authorized interactive Mac acceptance

Use an isolated build/data directory with synthetic text, rich text, transparent PNG, portrait image, multipage TIFF, file references and missing files. Do not use a maintainer's daily history. Record OS, architecture, build, display resolution/scaling and fixture identity.

Run report section 5.3's light/dark, standard/compact, 280/340/520-point matrix; hidden contents with Space/Command-I/VoiceOver and delayed OCR; deletion confirmation/cancel/Undo; queue replacement/retry/shortcut conflicts; Tab/Shift-Tab/IME; settings draft and permission round trips; file mutation/replacement/deletion and slow-volume previews. Validate actual target receipt separately from `commandSent`. This repository change does not provision or grant TCC access to an interactive machine.

## Performance cadence

Run the report's B01–B09 matrix for release candidates and periodically on an authorized idle test Mac. Keep the same hardware/build/fixtures for comparisons; preserve raw samples and fixture scale. Existing `SystemBenchmarkTests` requires the complete fixture manifest/database and output variables documented in the review. Do not enable that gate with missing fixtures. `ThumbnailMemoryBenchmark` uses a hosted test process and must not be labeled as production-app RSS.

The new focused search sampler can be invoked with `LOCALCLIP_REVIEW_BENCHMARK=1`, `LOCALCLIP_REVIEW_BENCHMARK_OUTPUT=<absolute-json-path>` and `scripts/test.sh -c release --no-parallel --filter nativeSearchSamples`. It records 30 raw samples for 5,000 indexed and missing-index synthetic records. It is a storage-test-host benchmark, not GUI latency or a long-running memory test.

AX timing is opt-in through the existing timing setting: `ax_remember_focus`, `ax_focus_check`, and `show_history_submitted`. The last stage ends at window submission, not first-frame presentation. Use the GUI probe/Instruments for real first-frame p50/p95 and a controlled slow target before changing AX scheduling. Identity, focus and terminal safety checks remain intact.
