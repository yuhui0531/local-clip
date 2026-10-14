# Schema compatibility and recovery (LC-014)

This change retains schema **4**. It introduces no migration and does not change original clipboard representations or settings serialization.

| Input | Supported behavior |
|---|---|
| New empty application directory | Create schema 4. |
| Valid schema 4 | Open and preserve IDs, representation hashes, titles, favorites, memberships/order and settings. |
| Schema 1–3 | Refuse to open; preserve the original directory. No currently supported migration is claimed. |
| Future/unknown schema | Refuse before configuring/writing application data. Preserve it for the matching application version. |
| Damaged schema 4 / failed recovery | Report failure and preserve evidence; do not reset the database to make startup succeed. |

Existing `olderSchemaIsRefusedWithoutMutation` and schema tests exercise refusal. Changing a version number in a current fixture is a refusal test, **not** proof of migration from a real historical schema.

## Recovery

1. Quit LocalClip and its updater before moving or replacing application data. Keep the entire original data directory, including any SQLite journal, as a recovery copy. The default directory is `~/Library/Application Support/LocalClip-Development/`; an explicitly configured test directory can differ.
2. For manual installation of an incompatible application, restore the matching application version while retaining its original data. Do not delete `History` or overwrite the only copy of the database.
3. For an interrupted built-in update, preserve the updater's previous app, data snapshot, transaction state and receipt. Use the recovery paths recorded by that transaction; do not combine files from different generations. A helper launch alone is not proof of recovery.
4. If normal rollback fails, retain both generations and diagnose the transaction before attempting manual restoration. Restore a complete, matching data snapshot only with the application stopped. Confirm `quick_check`, original representation hashes, IDs, titles, favorites, category order and settings using a copy before using the restored directory.

## Gate before the next schema change

Before shipping schema 5 (or another version), explicitly select supported source versions and obtain genuine synthetic fixtures made by those versions. Implement ordered transactional migrations with a verified pre-migration backup, fault injection and rollback. Verify every representation hash, ID, title, favorite, category membership/order and setting. Exercise both manual replacement and the signed updater's startup receipt/rollback paths. Unsupported future versions must continue to be preserved and refused. This is a release prerequisite, not an instruction to invent migrations now.
