# T0: ADR + Config skeleton (v0.15.0-prep)

Date: 2026-06-16
Author: Mavis (Mavis <AI@minimax.io>)
Worktree: `/private/tmp/dv-p0` on branch `feat/p0-adr-config-skeleton`

## Scope

Locked the design direction for the DreamVault v1.0 core markdown app
(spec `docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`)
without writing any feature implementation. Three ADRs + the bare data model
+ config schema changes those ADRs require so downstream tickets can build
on stable foundations.

## ADRs added

- `docs/adr/0001-notes-as-primary-writing-surface.md` — `notes/` becomes
  the primary user writing surface, alongside the existing `raw/`, `wiki/`,
  `archive/` directories.
- `docs/adr/0002-git-as-optional-versioning.md` — Git moves behind a
  `VersioningAdapter` protocol; the core never requires it.
- `docs/adr/0003-six-state-memory-lifecycle.md` — `MemoryStatus` expands
  from 3 to 6 states; salience formula expands from 3 to 5 weights.

## Code changes

- `Sources/DreamEngine/Models.swift`:
  - `MemoryStatus` adds `.reinforced`, `.decayed`, `.conflict` cases
  - `Memory` adds `lastReinforcedAt: Date?` and `salienceScore: Double?`
  - Custom `init(from decoder:)` extended with `decodeIfPresent` for both
    new fields (backward compatible with v0.14.x ledger.json)
- `Sources/DreamEngine/DreamConfig.swift`:
  - `VaultConfig.DecayBlock` adds 4 new fields: `wSource`, `wUser`,
    `reinforcedDecayDays`, `decayedSalienceThreshold`
  - Custom `init(from decoder:)` with `decodeIfPresent` for all new fields
    (backward compatible with v0.14.x `.dream/config.json`)

## Tests added

14 new test cases, all green:

- `Tests/DreamEngineTests/MemoryStatusExpansionTests.swift` (8 cases):
  6-state round-trip, all 6 rawValue present, legacy ledger decode for
  candidate/durable/archived, new field defaults, full encode round-trip
- `Tests/DreamEngineTests/DecayBlockExpansionTests.swift` (5 cases):
  default weight values, decay-vs-archive threshold invariant, legacy
  config JSON decode, full round-trip, end-to-end VaultConfig loader

## Validation

- `swift build`: clean (80/80 targets compiled)
- `swift test`: **707 tests, 0 failures, 0 skipped** (baseline 693 + 14 new)
- No existing tests touched
- No existing call sites modified (existing `MemoryStatus.candidate`,
  `.durable`, `.archived` usages continue to compile because new cases are
  additive)

## NOT in scope (deferred to later tickets)

- `VersioningAdapter` protocol + NoOp + Git impls → T1
- `VaultStore` consolidation → T2
- `RawImporter` dual-write to `notes/` → T3
- GUI re-shell to Sidebar/NoteList/Editor/Inspector → T4-T8
- `DreamCycle` integration of new pipeline steps → T10
- `Reinforcer` lifecycle wiring → T15
- `Decayer` 5-weight salience rewrite → T16
- Conflict review UI → T17
- Inspector lifecycle chips → T18
- Settings Git toggle + embedding search → T19-T21

## Merge plan

1. `git add docs/adr/ Sources/DreamEngine/Models.swift
   Sources/DreamEngine/DreamConfig.swift Tests/DreamEngineTests/MemoryStatusExpansionTests.swift
   Tests/DreamEngineTests/DecayBlockExpansionTests.swift`
2. `git commit -m "feat(T0): ADR + 6-state MemoryStatus + 5-weight DecayBlock skeleton"`
3. `git checkout main && git merge --no-ff feat/p0-adr-config-skeleton`
4. `git worktree remove /private/tmp/dv-p0 && git worktree prune`
