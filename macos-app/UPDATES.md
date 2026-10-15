# LocalClip updates

LocalClip downloads new releases when the existing automatic-update preference is enabled. Manual checks also download available updates. Downloaded archives survive restart and are reverified before use. Only **安装并重启** starts the installer; ordinary quit never installs.

The updater uses an Ed25519-signed `update.json` plus a raw 64-byte `update.sig`, with a SHA-256 digest and byte count for the versioned ZIP. This signing key is independent of Apple Developer ID. The installed app pins the public key in `LocalClipUpdatePublicKey`. Ad-hoc code signatures are supported; Gatekeeper and Accessibility permissions are not bypassed.

## Release setup

The initial private key is stored locally in `macos-app/.update-signing/private-key` (mode 0600, ignored by Git). Preserve it securely. Only the public key is committed. Configure the repository's Actions secret before publishing a tag:

```sh
gh secret set LOCALCLIP_UPDATE_PRIVATE_KEY --repo yuhui0531/local-clip < macos-app/.update-signing/private-key
```

Do not regenerate the key after distributing an update-enabled app. Losing the key prevents signing future updates for those installations. Key rotation is not implemented.

The release workflow builds and signs the helper, packages the final ZIP, then generates `update.json` and `update.sig`. Missing or mismatched keys stop publication. Version and build numbers must both increase. The first updater-enabled version still requires one manual installation by existing users.

For a local package:

```sh
bash macos-app/scripts/build-app.sh release
bash macos-app/scripts/package-dmg.sh
LOCALCLIP_UPDATE_PRIVATE_KEY="$(cat macos-app/.update-signing/private-key)" bash macos-app/scripts/sign-update.sh
```

## Failure handling and recovery

- Invalid signatures, checksums, versions, architectures, or bundle identities stop before replacement.
- The helper preflights the destination before the running app exits. Read-only volumes, unwritable directories, and insufficient space fail without privilege escalation.
- After exit, the helper takes the same storage lock as the app, snapshots the full local data directory, and atomically exchanges the app bundles. No fallback deletes the old app first.
- The new app acknowledges readiness only after store recovery succeeds. Launch failure or missing readiness within 45 seconds stops the new process before restoring the snapshot and old app. If another instance holds the storage lock or a process cannot be stopped, recovery stops and retains both generations rather than overwriting live data.
- Each attempt writes a session record to `~/Library/Application Support/LocalClip-UpdateSessions/<id>.json` before creating any workspace, and holds a per-session lock for the helper's lifetime. Phases (`preparing`, `ready`, `snapshotting`, `swapping`, `awaitingReceipt`, `succeeded`, `rollingBack`, `rolledBack`, `rescueRequired`, `abortedBeforeSwap`) are persisted atomically; `swapping` is written before the bundle exchange.
- Cleanup runs only for an unlocked session whose terminal state is confirmed by disk evidence (installed and candidate bundle build numbers), never from names, age, PIDs, or missing markers. Items are first renamed exclusively inside their own parent and their inode re-checked before removal. Cleanup failures only add warnings ("部分临时文件未清理"); they never change a success into a failure or trigger rollback.
  - Success: the session is marked `succeeded` first; then the download and the workspace holding the old app are removed.
  - Failure before swap: the workspace (candidate only) and its empty snapshot are removed; the download is kept while the old app still needs to read `result.txt`, then released by the app.
  - Rollback: the workspace holding the failed new app is removed; the data snapshot is **kept**, since it may hold the only copy of new-generation writes.
  - `rescueRequired`, `rollingBack`, unknown or contradictory states: everything is retained for manual recovery.
- The app runs the same compensation in the background after startup (again about 45 seconds later) and on every maintenance cycle, covering helpers that were killed or older helpers (legacy `result.txt` formats are migrated after a 120-second quiet period). Active downloads and verified ready packages are excluded.
- Success data snapshots: at most the latest one is kept, and it expires 7 days after the update succeeded (checked on startup and every maintenance cycle, not only on the next update). Rollback and rescue snapshots are never pruned automatically. Delete them manually only after verifying the data. Allow disk space for the ZIP, both apps, and a full data snapshot.
- The settings page shows the latest session result (falling back to the legacy `result.txt`). After it has been seen once, it is prefixed with "上次更新：". Recovery after power loss or storage hardware failure is not guaranteed; retained bundles and snapshots support manual recovery. Do not run two updater-enabled installations against the same data store simultaneously.

## Verification

```sh
bash macos-app/scripts/test.sh --no-parallel
python3 macos-app/scripts/test-update-installer.py
# Optional: also run scenarios against helpers built from older commits
LOCALCLIP_LEGACY_UPDATERS=/path/a/LocalClipUpdater:/path/b/LocalClipUpdater python3 macos-app/scripts/test-update-installer.py
```

The installer script uses temporary ad-hoc-signed fixture apps and synthetic data. A Debug-only isolation environment (`LOCALCLIP_UPDATER_TEST_ROOT`, accepted only under `/private/tmp`) redirects its store, session records, backups, update cache, and lock into that root; Release ignores that environment. It exercises real signature checks, process exit, LaunchServices, atomic replacement, startup failure, rollback, cancellation, snapshot failure, repeated updates, and compensation cleanup without touching the installed LocalClip or user history. It does not prove Gatekeeper behavior for an internet-quarantined release or continued Accessibility authorization.
