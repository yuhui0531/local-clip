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
- Old apps remain under `.LocalClip-update-<UUID>/candidate/LocalClip.app` beside the installation. Data snapshots remain under `~/Library/Application Support/LocalClip-UpdateBackups/`. On rollback the snapshot path instead preserves the failed new generation of data. Nothing is automatically pruned; delete old recovery folders manually only after verifying the update. Allow disk space for the ZIP, both apps, and a full data snapshot.
- Update status is retained in the update cache's `result.txt`. Recovery after power loss, forced helper termination, or storage hardware failure is not guaranteed automatically; retained bundles and snapshots support manual recovery. Do not run two updater-enabled installations against the same data store simultaneously.

## Verification

```sh
bash macos-app/scripts/test.sh --no-parallel
python3 macos-app/scripts/test-update-installer.py
```

The installer script uses temporary ad-hoc-signed fixture apps and synthetic data. A Debug-only isolation environment redirects its store and lock; Release ignores that environment. It exercises real signature checks, process exit, LaunchServices, atomic replacement, startup failure, and rollback without touching the installed LocalClip or user history. It does not prove Gatekeeper behavior for an internet-quarantined release or continued Accessibility authorization.
