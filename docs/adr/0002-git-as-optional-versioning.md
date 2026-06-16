# ADR-0002: Git is an optional versioning adapter, not a core dependency

Date: 2026-06-16
Status: Accepted
Supersedes: nothing
Context spec: `docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`

## Context

DreamVault v0.14.1 treats git as a hard dependency of the dream pipeline.
`DreamCycle.runOnce()` ends with `git commit`; if the vault has no `.git/`,
`DreamCycle` either creates one implicitly (via `GitRunner`) or fails the
whole run. The Settings view surfaces Git status, the menu bar shows Git
state, and `Rollback Last Dream` is wired directly to `git revert HEAD`.

This coupling produces three concrete problems the spec calls out:

1. **First-launch friction.** A user opening a brand-new vault must accept
   the Git initialization step before they can run their first dream. There
   is no "I just want to use this as a Markdown app today" path.
2. **P0 workflow fragility.** Every failure mode in the spec's Error Handling
   section can be triggered by Git itself (not in the user's control —
   `git` missing, `git` hung on a network operation, lockfile contention,
   pre-commit hook rejecting). When Git fails, the dream run fails, even
   though the memory work succeeded.
3. **Wrong inversion of control.** The user wants version safety for some
   workflows (dream output, hand-edited wiki pages) but not for others
   (every keystroke in `notes/`). A blanket Git-everything model can't
   express that.

The spec (`docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`
§Product Boundary, §Git As Optional Versioning) is unambiguous:

> DreamVault's core is not Git. DreamVault must work as a complete local
> Markdown app without a Git repository.

> No P0 workflow may fail solely because Git is missing.

## Decision

Reframe Git as a `VersioningAdapter` implementation, selected at runtime
based on a Settings toggle and (optionally) on vault state:

| Settings state | Adapter selected       | When chosen                                            |
|----------------|------------------------|--------------------------------------------------------|
| Off            | `NoOpVersioningAdapter`| Default for users who don't want version control       |
| Detect         | `NoOp` or `GitVersioningAdapter` | Adapter picked at vault open based on `.git/` presence |
| On             | `GitVersioningAdapter` | User explicitly wants full Git workflow                |

The `VersioningAdapter` protocol exposes the operations `DreamCycle`,
`AppModel`, and `DreamPanel` actually use today:

```swift
protocol VersioningAdapter {
    func commit(message: String) async throws -> String? // returns commit hash or nil if nothing to commit
    func status() async throws -> VersioningStatus
    func revertLast() async throws
    func lastCommitSummary() async throws -> LastCommitSummary?
}
```

`GitRunner` becomes `GitVersioningAdapter: VersioningAdapter`. A new
`NoOpVersioningAdapter` does nothing and returns nil/empty for every call.
`DreamCycle.runOnce()` ends with `try? await self.versioningAdapter.commit(...)`
rather than the current direct `git.run([...])`. Failures in the adapter are
logged but do not fail the dream run.

`SnapshotStore` (Phase 2, T12) provides a non-Git safety net: every dream
run writes `.dream/snapshots/<ts>-pre.zip` and `<ts>-post.zip`, so even users
on `NoOp` have a rollback path.

The existing `GitStatusBanner`, `DiffViewerView`, and Rollback menu items
become visible only when the active adapter is `GitVersioningAdapter`.

## Consequences

Positive:

- First launch on a fresh vault requires zero Git decisions.
- Dream runs no longer fail because of Git. The worst case is
  "versioning status shows failure" — the memory work itself is preserved.
- Users who never wanted Git (the majority of people who just want to write
  notes) can use DreamVault cleanly.
- Future versioning backends (e.g., a custom CRDT, jj, Pijul) plug in by
  implementing the same protocol.

Negative / costs:

- The `VersioningAdapter` boundary is a non-trivial refactor of the current
  `GitRunner` call sites. Specifically `DreamCycle`, `AppModel`, and the
  rollback confirmation flow must be audited.
- Rollback semantics diverge by adapter: Git offers atomic commits;
  `SnapshotStore` offers coarse-grained zip snapshots. The UI must be
  honest about which the user is getting.
- The current `GitStatusParser` becomes adapter-specific. Pull it under
  `GitVersioningAdapter` so the core doesn't carry Git knowledge.

## Implementation tickets

- **T1** (Phase 0): introduce `VersioningAdapter` protocol + NoOp + Git impls
- **T12** (Phase 2): `SnapshotStore` provides the non-Git rollback path
- **T19** (Phase 4): Settings UI for Off/Detect/On; hide Git-specific UI on NoOp

## References

- Spec: §Product Boundary, §Git As Optional Versioning, §Error Handling
- Current code: `Sources/DreamEngine/GitRunner.swift`,
  `Sources/DreamEngine/DreamCycle.swift` (`runOnce`),
  `Sources/dream/Entry.swift` (`AppModel.runDream`, `rollback`,
  `requestRollback`, `confirmRollback`)
- Pattern reference: `Sources/DreamEngine/VaultBackup.swift` (zip-based
  safety net already exists for `P7-T2`)
