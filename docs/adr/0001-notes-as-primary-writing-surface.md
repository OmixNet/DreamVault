# ADR-0001: `notes/` becomes the primary user writing surface

Date: 2026-06-16
Status: Accepted
Supersedes: nothing
Context spec: `docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`

## Context

DreamVault v0.14.1 has three user-visible top-level directories in the vault:
`raw/`, `wiki/`, `archive/`. `raw/` was the only place users could write — the
engine treated raw as a quasi-immutable source-of-truth that the dream pipeline
reads and the user writes. In practice this produces two failure modes that the
spec surfaces:

1. **Imported knowledge gets dream-processed on arrival.** A user dropping a
   PDF transcript into `raw/` immediately becomes a candidate memory. There is
   no "let me annotate this first" stage.
2. **There is no notion of "I wrote this myself for my own use."** User-authored
   notes share storage with captured source material, so the dream pipeline
   can't distinguish between "ephemeral captured log" and "this is my journal,
   treat it as already-curated."

The spec (`docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`
§Vault Layout) introduces a fourth top-level directory `notes/` and makes it
the primary writing surface. `raw/` becomes strictly immutable source material;
durable knowledge still goes to `wiki/` and `MEMORY.md`; `archive/` is the
recovery bucket.

## Decision

Adopt the spec's vault layout verbatim:

```text
MyVault/
├─ raw/        # immutable source material (engine + user can view, only RawImporter can write)
├─ notes/      # primary user writing surface (markdown notes the user edits)
├─ wiki/       # generated/curated durable knowledge (read + edit, with dream-report audit)
├─ archive/    # decayed but recoverable memories (searchable, never physically deleted)
├─ MEMORY.md   # durable high-signal memory (same rules as wiki/)
├─ .dream/     # engine state: ledger.json, reports/, snapshots/, config.json
└─ .git/       # optional, only if Git mode is enabled (see ADR-0002)
```

Rules:

- `raw/` is immutable from the app UI. The editor will block edits and
  `RawReadonlyGuard.makeReadonly` already enforces 0o555 at the file level.
- Markdown imports via `RawImporter` write two files: an immutable copy in
  `raw/` AND, when the source is Markdown, an editable copy in `notes/`.
  Non-Markdown (`.txt`, etc.) imports stay raw-only unless the user
  explicitly converts.
- `notes/` is the new home for the main editor surface. New notes created
  from the UI (Cmd-N) land in `notes/`, not vault root.
- `wiki/` and `MEMORY.md` remain durable surfaces. The dream pipeline writes
  here after consolidate; users can hand-edit, but every dream run writes a
  report describing what changed.
- `archive/` is recovery, not deletion. `VaultSearcher` must continue to index
  archived memories.

## Consequences

Positive:

- Captures and user notes have separate lifecycles. The dream pipeline can
  prioritize differently, decay differently, and decide differently about
  what becomes durable.
- The "I want to import a PDF and annotate it" workflow becomes
  straightforward: import lands in `raw/`, user creates a `notes/` file with
  the annotation, dream runs eventually consolidate both.
- GUI re-shell (Phase 1) gets a clean answer to "what's in the sidebar":
  Inbox / Notes / Raw / Wiki / Archive / Memory / Reports — `notes/` is its
  own group, distinct from `raw/`.

Negative / costs:

- Existing v0.14.1 vaults have no `notes/` directory. We must ship a
  one-time migration helper that creates the directory and (optionally)
  re-classifies existing top-level `*.md` files. The default for the
  migration should be conservative: do not move user files automatically;
  only create `notes/`.
- `Gatherer` currently scans `raw/` only. Phase 2 ticket T10 will extend it
  to scan `notes/` too. Until then, notes won't feed the dream pipeline.
- `Persister` writes to `wiki/` and `MEMORY.md`; this ADR does not change
  that path. We need to be careful that nothing in this ADR implies
  dream output should land in `notes/` — it should not.

## Implementation tickets

This ADR is a design decision only. Implementation is split across:

- **T2** (Phase 0): `VaultStore` gains `notesDir` and `ensureNotesDir()`
- **T3** (Phase 0): `RawImporter` writes dual copies for Markdown imports
- **T4–T7** (Phase 1): GUI re-shell exposes `notes/` as its own sidebar group
- **T10** (Phase 2): `Gatherer` scans both `raw/` and `notes/`

## References

- Spec: `docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`
  §Vault Layout, §Data Flow (Create Or Edit Note, Import Markdown)
- Current behavior: `Sources/DreamEngine/RawImporter.swift`,
  `Sources/DreamEngine/RawReadonlyGuard.swift`,
  `Sources/dream/AppActions.swift` (`newNote`)
