# ADR-0003: Six-state memory lifecycle, salience with five weighted signals

Date: 2026-06-16
Status: Accepted
Supersedes: nothing
Context spec: `docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`

## Context

DreamVault v0.14.1 has three memory lifecycle states defined in
`Sources/DreamEngine/Models.swift`:

```swift
public enum MemoryStatus: String, Codable, Sendable {
    case candidate   // single-source observation, enters wiki candidate zone
    case durable     // multi-source support, enters MEMORY.md
    case archived    // decayed, moved into archive, recoverable
}
```

The salience score used to decide "is this memory decaying?" is a 3-signal
weighted sum computed in `Decayer.swift`:

```swift
salience = w_r * recency + w_f * frequency + w_l * linkage
```

where `recency` is `exp(-Δt/τ)` with τ multiplied by a `DecayClass` factor
(slow ×3.0 / normal ×1.0 / fast ×0.3).

The spec (`docs/superpowers/specs/2026-06-16-dreamvault-core-markdown-app-design.md`
§agentmemory-Inspired Memory Algorithms) is more nuanced. It calls for:

- Six lifecycle states: `candidate`, `durable`, `reinforced`, `decayed`,
  `archived`, `conflict`.
- Five weighted signals in salience: recency, frequency, linkage,
  **source support**, **user reinforcement**.
- Conflict surface (not silent deletion).
- Conservative bias toward under-archiving in v1.

The 3-state model is insufficient for two reasons:

1. **No representation of "this memory is currently in heavy use."** A memory
   that has been reinforced by access, links, and explicit user keep is
   conceptually distinct from one that just crossed the durability threshold
   five minutes ago. They decay at different rates.
2. **No representation of "this memory is fading but not yet archived."**
   The current model jumps directly from `durable` to `archived` when
   salience drops below threshold, with no intermediate observability.

The 3-signal salience is similarly blind: two memories with the same
recency/frequency/linkage profile score identically even if one is supported
by 5 raw sources and the user has explicitly pinned it, while the other
is supported by 1 raw source with no user signal.

## Decision

### Lifecycle states

Adopt the spec's six states verbatim:

| State        | Meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| `candidate`  | Observed once or weakly supported; not yet in `MEMORY.md`               |
| `durable`    | Evidence-backed; written to `MEMORY.md` or `wiki/`                     |
| `reinforced` | Recently used, linked, or explicitly confirmed; decays slower          |
| `decayed`    | Lower salience than its durable baseline but still active               |
| `archived`   | Moved out of active set; still searchable, recoverable                 |
| `conflict`   | Contradicts another memory; surfaced for review, not silently deleted  |

Transitions:

- `candidate` → `durable` (evidence threshold met, 2+ independent sources)
- `durable` → `reinforced` (access / link / explicit keep signal)
- `reinforced` → `durable` (reinforcement signal ages past threshold)
- `durable` → `decayed` (salience drops below durable floor but above
  archive threshold)
- `decayed` → `archived` (salience + age criteria met)
- `archived` → `durable` (user un-archives)
- any → `conflict` (ContradictionDetector flags it)
- `conflict` → `durable` / `archived` (user resolves the conflict)

Archived memories stay searchable. Conflicts stay in the active set until
resolved — they are NOT auto-archived.

### Salience formula

Replace the 3-signal formula with the spec's 5-signal formula:

```text
salience = recencyWeight    * recency
         + frequencyWeight  * frequency
         + linkageWeight    * linkage
         + sourceWeight     * sourceSupport
         + userWeight       * userReinforcement
```

All five weights live in `.dream/config.json` under
`VaultConfig.DecayBlock`. Defaults are conservative: bias toward under-archiving
in v1, meaning archive threshold lowered (e.g., 0.10 instead of current 0.15)
or the `userWeight` and `sourceWeight` defaults raised relative to the
others. Exact numbers land in T16 (Phase 3).

`sourceSupport` = normalized count of distinct raw/notes sources supporting
the memory (already tracked as `Memory.distinctSourceCount`).
`userReinforcement` = normalized count of explicit keep / pin / confirm
signals, with decay over time.

The existing 3 weights stay as defaults so that pre-existing
`.dream/config.json` files continue to load. New weights default to
`0.10` each, with `sourceWeight` and `userWeight` set so their defaults sum
to `0.20` (matching what the spec implies for under-archiving bias).

### Conflict representation

The existing `Memory.contradicts: [String]` field is preserved and is the
authoritative link for "which other memories conflict with this one." The
new `conflict` lifecycle state is set whenever
`!Memory.contradicts.isEmpty`. The `ConflictReviewView` (Phase 3, T17)
consumes this state.

## Backward compatibility

`MemoryStatus` is `String, Codable`. Old ledger.json files encode only
`candidate` / `durable` / `archived`. The custom
`init(from decoder:)` (already in `Models.swift`) must be extended to:

- Continue accepting old three-state strings without error.
- For any old memory, set `lastReinforcedAt = nil` and `salienceScore = nil`.
- After load, the dream pipeline computes the missing fields rather than
  requiring them to be present in JSON.

`VaultConfig.DecayBlock` already supports `decodeIfPresent` for the three
existing weights (verified by reading `DreamConfigLoader`). New weights
default via the `DecayBlock.init` parameter list, so old config files
silently pick up the conservative defaults on next save.

## Consequences

Positive:

- Lifecycle becomes observable at six distinct points instead of three.
  Inspector UI (Phase 1, T7) can show the user exactly where each memory is
  in its life.
- Salience reflects what the user actually cares about (explicit keep +
  source corroboration) rather than only access patterns.
- Conflicts are no longer hidden in `Memory.contradicts`; they have a
  first-class lifecycle state and a dedicated review UI.

Negative / costs:

- Six states means more state-transition tests. Phase 3 must cover all
  realistic transitions plus invalid ones (e.g., `archived → reinforced`
  should be rejected; must go through `durable` first).
- Five-weight salience has more parameters to tune. We commit to
  "conservative under-archiving in v1" and document the exact numbers in
  T16 with reasoning per weight.
- The `Memory` struct grows two new optional fields. JSON size impact is
  negligible; semantic clarity gain is significant.

## Implementation tickets

- **T0** (this ticket): ADR + `Models.swift` adds three new cases to
  `MemoryStatus` + two new optional fields on `Memory` + five-weight fields
  on `VaultConfig.DecayBlock` + backward-compatible decode
- **T15** (Phase 3): `Reinforcer` wires access/link/source/user signals into
  the lifecycle (drives `durable → reinforced` and `decayed → durable`)
- **T16** (Phase 3): `Decayer` rewrites salience to 5 weights with
  conservative defaults
- **T17** (Phase 3): Conflict review UI
- **T18** (Phase 3): Inspector surfaces the six states as colored chips

## References

- Spec: §agentmemory-Inspired Memory Algorithms, §Data Flow (Run Dream)
- Current code: `Sources/DreamEngine/Models.swift`,
  `Sources/DreamEngine/Decayer.swift`,
  `Sources/DreamEngine/ContradictionDetector.swift`,
  `Sources/DreamEngine/Reinforcer.swift`
- Upstream pattern: `agentmemory-main/src/functions/consolidate.ts`,
  `consolidation-pipeline.ts`, `auto-forget.ts` (4-tier model + decay)
