# DreamVault Core Markdown App Design

Date: 2026-06-16

## Decision

DreamVault will become a personal Markdown knowledge app with a Tolaria-style user experience, DreamVault's native macOS architecture and memory engine, and selected agentmemory-inspired memory lifecycle algorithms.

The product direction is:

> DreamVault core architecture + Tolaria experience and UI + agentmemory memory algorithms.

This is not a three-codebase merge. DreamVault remains the app and engine. Tolaria is the interaction and visual reference. agentmemory is an algorithmic reference for memory lifecycle, search, reinforcement, and retrieval ranking.

## Product Boundary

DreamVault's core is not Git. DreamVault must work as a complete local Markdown app without a Git repository.

Core responsibilities:

- Open and manage a local Markdown vault.
- Create, edit, save, search, and organize Markdown notes.
- Preserve immutable source material in `raw/`.
- Keep editable working notes in `notes/`.
- Build durable knowledge in `wiki/` and `MEMORY.md`.
- Move low-salience memories to `archive/` instead of deleting them.
- Run dream memory processing over raw material and notes.
- Track memory lifecycle: candidate, durable, reinforced, decayed, archived, conflict.
- Provide a Tolaria-style desktop workflow: sidebar, note list, editor, inspector, quick open, command palette, backlinks, related notes, and frontmatter inspection.

Non-core optional responsibilities:

- Git commit, diff, history, and rollback.
- Remote sync.
- MCP server integration.
- Multi-agent hooks.
- Cloud account or collaboration features.

Git should remain available as an optional version-safety enhancement. The app must not require Git for first launch, note editing, dream runs, search, or memory persistence.

## Architecture

DreamVault keeps the SwiftPM and SwiftUI architecture:

- `DreamEngine` remains UI-independent and owns memory processing, vault scanning, search, persistence, lifecycle scoring, and AI-provider abstractions.
- `dream` remains the executable target and hosts both CLI and SwiftUI app entry points.
- SwiftUI becomes the main desktop app surface.
- Existing Git-specific code stays behind an optional adapter boundary.

Target module shape:

```text
DreamVault
├─ DreamEngine
│  ├─ VaultStore              # file-first vault access
│  ├─ RawImporter             # raw ingest + editable note copy
│  ├─ VaultSearcher           # keyword/frontmatter/wikilink search
│  ├─ WikilinkIndex           # backlinks + graph edges
│  ├─ DreamCycle              # gather -> consolidate -> decay -> persist
│  ├─ Consolidator            # evidence-backed candidate memories
│  ├─ Decayer                 # memory lifecycle scoring
│  ├─ Reinforcer              # access/link/reference reinforcement
│  ├─ Persister               # MEMORY.md, wiki, archive, reports
│  ├─ SnapshotStore           # local non-Git snapshots and dream reports
│  └─ VersioningAdapter       # optional Git implementation
└─ dream SwiftUI app
   ├─ Sidebar
   ├─ NoteList
   ├─ MarkdownEditor
   ├─ Inspector
   ├─ CommandPalette
   ├─ SearchSurface
   ├─ DreamPanel
   └─ Settings
```

`DreamCycle` should be treated as:

```text
gather -> consolidate -> decay -> persist
```

Git commit is not part of the core dream pipeline. When Git is enabled, it runs after persistence through `VersioningAdapter`.

## Vault Layout

The vault remains plain files:

```text
MyVault/
├─ raw/                  # immutable source material
├─ notes/                # editable user notes
├─ wiki/                 # generated or curated durable knowledge
├─ archive/              # decayed but recoverable memories
├─ MEMORY.md             # durable high-signal memory
├─ .dream/
│  ├─ ledger.json        # memory lifecycle state
│  ├─ reports/           # dream reports
│  ├─ snapshots/         # local non-Git safety snapshots
│  └─ config.json
└─ .git/                 # optional, only if Git mode is enabled
```

Rules:

- `raw/` is immutable from the app. It can be viewed and searched, but not edited in the normal editor.
- Markdown imports create an immutable raw record and, when appropriate, an editable copy in `notes/`.
- `.txt` and non-Markdown source imports may stay raw-only unless the user explicitly converts them.
- `notes/` is the main writing surface.
- `wiki/` and `MEMORY.md` are durable memory surfaces that can be inspected and edited, but dream reports must show what changed.
- `archive/` is not deletion. Archived memories stay searchable.
- `.dream/` contains engine state and reports. It must be reconstructible or inspectable enough that data remains portable.

## Tolaria-Style Experience

Tolaria is the target interaction model for the GUI. DreamVault should feel like a quiet, fast, file-first Markdown knowledge app, not an engineering control panel.

Primary layout:

```text
┌────────────┬──────────────┬──────────────────────────┬───────────────┐
│ Sidebar    │ Note List    │ Markdown Editor          │ Inspector     │
│            │              │                          │               │
│ Vault      │ Current view │ Source / preview / split │ Frontmatter   │
│ Inbox      │ Search hits  │ Autosave                 │ Backlinks     │
│ Notes      │ Recent notes │ Wikilinks                │ Related notes │
│ Raw        │ Raw items    │ Raw read-only preview    │ Dream status  │
│ Wiki       │ Wiki pages   │                          │               │
│ Archive    │              │                          │               │
└────────────┴──────────────┴──────────────────────────┴───────────────┘
```

Expected UI behavior:

- The app opens directly into the vault workspace, not a marketing or setup screen after first-run configuration.
- Sidebar groups are stable and simple: Inbox, Notes, Raw, Wiki, Archive, Memory, Reports.
- Note list supports recent notes, folder views, search results, raw candidates, and wiki pages.
- Editor supports source, preview, and split modes.
- Raw files open in read-only preview/source mode with a clear lock state.
- Autosave is default for editable notes.
- External file changes refresh clean notes without overwriting dirty editor buffers.
- Inspector shows frontmatter, backlinks, related notes, outgoing wikilinks, source refs, lifecycle state, and dream provenance.
- Command palette provides common actions: new note, quick open, search, import, run dream, open memory, open settings.
- Keyboard navigation must be first-class.
- Visual style should be restrained, dense, and practical. Use cards only for repeated items, modal surfaces, and framed tools.

Features to avoid in the first version:

- Tolaria's multi-workspace mounting.
- Full AI agent workspace UI.
- Collaboration.
- Rich property database behavior.
- Complex view builder.
- Cross-platform Tauri shell.
- Plugin marketplace or extension system.

## agentmemory-Inspired Memory Algorithms

agentmemory should influence the memory model and retrieval behavior, not the app architecture.

Memory lifecycle states:

- `candidate`: observed once or weakly supported.
- `durable`: evidence-backed and written to `MEMORY.md` or `wiki/`.
- `reinforced`: recently used, linked, or confirmed.
- `decayed`: lower salience but not archived.
- `archived`: moved out of the active set, still searchable.
- `conflict`: contradicts another memory and needs review.

Signals:

- Recency: recently accessed or edited memories score higher.
- Frequency: repeatedly referenced memories score higher.
- Linkage: memories with more backlinks, wikilinks, or graph neighbors score higher.
- Source support: memories supported by multiple raw or note sources score higher.
- User reinforcement: explicit keep/pin/confirm actions score higher.
- Contradiction: conflicting memories must be surfaced for review, not silently deleted.

First implementation scoring can stay simple:

```text
salience = recencyWeight * recency
         + frequencyWeight * frequency
         + linkageWeight * linkage
         + sourceWeight * sourceSupport
         + userWeight * userReinforcement
```

The exact weights should live in `.dream/config.json` with conservative defaults. The first version should prefer under-archiving over losing useful context.

Retrieval should start with local, explainable ranking:

- text match
- title match
- frontmatter match
- wikilink/backlink relation
- lifecycle salience
- source proximity

Semantic embedding search can be added later behind a provider boundary.

## Data Flow

### Create Or Edit Note

```text
User edits note
-> MarkdownEditor autosaves to notes/
-> VaultStore updates file metadata
-> WikilinkIndex refreshes affected note
-> Inspector updates backlinks and related notes
-> optional SnapshotStore records a lightweight local snapshot
```

### Import Markdown

```text
User imports file
-> RawImporter writes immutable raw copy
-> RawImporter creates editable notes copy for Markdown
-> UI selects editable note
-> raw source remains linked through source refs
```

### Run Dream

```text
User or scheduler runs Dream
-> Gatherer scans raw/ and notes/
-> Consolidator creates evidence-backed candidate memories
-> Decayer updates lifecycle state
-> Reinforcer applies usage/link/source signals
-> Persister updates MEMORY.md, wiki/, archive/, ledger
-> SnapshotStore writes dream report and local snapshot
-> optional VersioningAdapter commits if Git mode is enabled
```

### Search

```text
Query
-> VaultSearcher runs keyword/frontmatter/title matching
-> WikilinkIndex adds graph-related candidates
-> lifecycle salience adjusts ranking
-> UI shows grouped results with source path and match reason
```

## Git As Optional Versioning

Git is a setting, not a core dependency.

Settings states:

- Off: no Git UI, no commit requirement, no Git errors.
- Detect: if the vault is already a Git repo, show optional version features.
- On: enable commit, diff, history, rollback, and post-dream auto-commit.

When Git is off, DreamVault still provides:

- `dream-report` records.
- `.dream/snapshots/` for lightweight local safety.
- visible changed-file summaries after dream runs.

When Git is on, DreamVault adds:

- optional status indicator.
- diff viewer.
- post-dream commit.
- rollback through Git.

No P0 workflow may fail solely because Git is missing.

## Error Handling

File writes:

- Use atomic writes for editable notes, ledger, reports, and generated wiki pages.
- On save failure, keep the editor buffer dirty and show a specific error.
- Never overwrite a dirty editor buffer with an external refresh.

Raw immutability:

- Attempts to edit `raw/` through the normal editor are blocked.
- Import must not mutate the original source file in place.

Dream run:

- If gather fails, no generated files are changed.
- If consolidate fails, keep imported notes and write a failed report.
- If persist fails, leave a failed report and keep previous durable memory.
- If optional Git commit fails, the dream run remains successful but versioning status shows failure.

Memory safety:

- Decay may archive, but must not physically delete notes or raw material.
- Conflicts become review items.
- Low-confidence candidate memories stay out of `MEMORY.md`.

## Testing Strategy

Engine tests:

- Raw import creates raw copy plus editable Markdown note copy.
- Raw files are read-only through app-level guards.
- Dream cycle runs without Git enabled.
- Dream cycle optionally calls versioning adapter when Git is enabled.
- Decayer archives instead of deleting.
- Reinforcer increases salience after access/link/user confirmation.
- Search ranks exact title/text matches and related backlinks predictably.

UI tests:

- Open vault and see Tolaria-style four-pane shell.
- Create note, type text, autosave, reopen, content persists.
- Import Markdown and auto-select editable note.
- Open raw file and verify editor is locked.
- Quick open navigates to a note.
- Search returns notes, raw items, wiki pages, and archived results.
- Inspector shows frontmatter and backlinks.
- Run Dream updates report surface without requiring Git.
- Enable Git setting and verify optional status surfaces appear.

Manual acceptance:

- The app feels like a Markdown app first, not a dream-engine dashboard.
- A user can use it daily without understanding Git.
- Dream reports are readable enough to audit what changed.
- All user content remains plain files in the vault.

## Implementation Phases

### Phase 1: Core Markdown Workspace

- Replace the current GUI emphasis with the Tolaria-style shell.
- Implement sidebar, note list, editor, inspector, quick open, search, and settings skeleton.
- Keep Git hidden unless enabled.
- Ensure notes can be created, edited, autosaved, reopened, and searched.

### Phase 2: Raw And Dream Integration

- Integrate raw import with editable Markdown copy behavior.
- Surface raw as read-only.
- Add Run Dream entry point.
- Show dream reports and generated memory changes.
- Ensure dream runs without Git.

### Phase 3: Memory Lifecycle

- Make candidate/durable/reinforced/decayed/archived/conflict states visible.
- Add reinforcement signals from access, links, and explicit user actions.
- Add related-note ranking from wikilinks and lifecycle salience.
- Add conflict review surface.

### Phase 4: Optional Git And Advanced Search

- Add Git setting and optional status/diff/history/rollback UI.
- Keep Git out of default workflow.
- Add embedding search only after keyword/graph search is stable.

## Acceptance Criteria

- DreamVault launches into a Tolaria-style Markdown workspace.
- A vault without `.git/` works fully.
- `raw/` is viewable but not editable.
- Markdown imports create editable notes where appropriate.
- Notes, wiki pages, memory, reports, and archive are plain local files.
- Run Dream updates memory surfaces and reports without requiring Git.
- Git features appear only when enabled.
- The first version removes nonessential agent, cloud, collaboration, and remote-sync features from scope.
