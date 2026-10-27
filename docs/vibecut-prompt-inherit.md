# VibeCut prompt inherit — integration contract

Quip can **one-way inherit** the prompt catalog from
[VibeCut](../../vibecut) (a sibling macOS project) into its own Prompts page. A
manual **Sync** button on the phone pulls VibeCut's real prompts into Quip,
tagged as inherited, merged into the existing list, each individually hide-able —
without clobbering your own prompts and without a connection flap.

This is deliberately **one-way** (VibeCut → Quip) and **manual** (no auto/live
sync). Edits belong in VibeCut; Quip is a refreshable consumer.

## Source of truth

- Base catalog: `<vibecut-repo>/shared/prompts.json` (git-tracked in the VibeCut project).
- User prompt packs: `~/Library/Application Support/VibeCut/packs/*.json`
  (`vibecutpack/1` files created/imported by VibeCut).
- Organization labels: `<vibecut-repo>/shared/prompt-organization.json`
  (optional; `{"version":1,"actions":{"<prompt id>":{"purpose","requirements","kind"}}}`).
- Repo path: `~/Projects/vibecut` by default, overridable on the Mac via
  `defaults write com.quip.mac vibecutRepoPath /path/to/vibecut`.

`prompts.json` shape (only the fields Quip reads):

```jsonc
{
  "version": "3.0",
  "preamble": "…shared architecture context…",   // NOT inherited (stripped)
  "categories": { "git": { "order": 6, "label": "Git & Deploy" } },
  "prompts": [
    {
      "id": "14-commit", "slug": "commit", "name": "Commit",
      "category": "git", "tags": ["workflow"],
      "prompt": "Write a commit…",                 // -> PromptEntry.body
      "mode": "paste", "type": "text", "skip_preamble": false,
      "purpose": "build", "requirements": ["project-tools"], "kind": "prompt"  // optional
    }
  ]
}
```

## What inherits (include filter)

A VibeCut entry becomes a Quip prompt **iff** all hold — "real prompts only":

- `kind` is not `runtime-command` or `local-command` (VibeCut machinery, never
  inherited, even with a body), AND
- `type` is `text` or absent, AND
- the `prompt` body is non-empty, AND
- `mode != "send"` (the send-immediately slash shortcuts like `/clear`,
  `/compact` are skipped) — **unless** `kind == "prompt"`, which ignores `mode`
  (VibeCut's send-mode "Proceed" prompt inherits). With no `kind`, the rule above
  is unchanged.

Everything else (screenshot / stats / shell / chain actions, empty bodies, and
the send shortcuts) is counted as *skipped* and reported in the sync ack.

Prompt-pack entries are merged after the base catalog and go through the same
filter/mapping rules. Corrupt pack files are skipped so one bad imported pack
cannot block sync of the base VibeCut catalog or other valid packs. A pack whose
top-level `format` is not exactly `vibecutpack/1` (missing included) counts as
unreadable the same way (Q-81).

VibeCut's shared `preamble` is **not** prepended — Quip inherits only the raw
per-prompt body.

## Field mapping (VibeCut → Quip `PromptEntry`)

| VibeCut | Quip `PromptEntry` | Notes |
|---|---|---|
| `name` | `label` | display title (falls back to the slug if name is empty) |
| `id`/`name` | `id = "vibecut__" + slug(name)` the first time; afterwards the remembered id (see below) | reserved namespace; slug = lowercase, non-`[a-z0-9]` runs → single `-`, trimmed |
| `prompt` | `body` | preamble stripped |
| `tags[]` + `category` + `"vibecut"` | `tags[]` | `"vibecut"` always present (dedup preserved) → drives the badge + hide |
| `purpose` | `tags[]` `purpose:<purpose>` | `build\|plan\|life\|mac\|other`; lets non-coding prompts be told apart |
| `requirements[]` | `tags[]` `needs:<r>` each | `chat\|project-tools\|web\|current-lookup`; e.g. `needs:chat`, `needs:project-tools` |
| `kind` | (filter only) | see include filter; not emitted as a tag |
| — | `targetAgent` | left nil |

`purpose` / `requirements` / `kind` come from the prompt row if present, else from
the `prompt-organization.json` annotation for the same `id`. Row fields win per
field, including an explicit empty `requirements: []` (VibeCut's
`applyOrganization` precedence). A missing or malformed organization file just
means no such tags. The `purpose:` / `needs:` tag spellings are a contract with
the iOS filters.

Intra-catalog id collisions get deterministic `-2`/`-3` suffixes (name-sorted for
stability). Empty slug → `vibecut__untitled-<n>`.

### Ids survive a rename (Q-79)

The Mac remembers VibeCut source `id` → Quip id in
`~/Library/Application Support/Quip/vibecut-ids.json` (missing or corrupt reads as
empty). A source already in the map keeps its Quip id when its name changes, so the
phone's hide state, project tags and usage ranking follow the prompt. Rules:

- Remembered ids are reserved before any name-derived id is assigned, so a new
  prompt whose slug equals one gets a `-2` suffix instead of taking it.
- A new source gets today's name-derived id, so existing ids need no migration.
- Two sources claiming one id: the first in name-then-id order keeps it.
- A prompt with no source `id` gets a name-derived id and is not remembered; a
  content duplicate collapsed into another row adds no map entry.
- Entries for sources missing from this sync are kept, so a prompt that comes back
  reuses its id.
- Map values outside the `vibecut__` namespace are ignored and dropped; the map can
  never point at one of your own files.
- The map is saved only after the batch write succeeded; a failed sync leaves it
  as it was.

## Reserved namespace & clean re-sync

Inherited files land as `vibecut__<slug>.txt` in
`~/Library/Application Support/Quip/prompts/`. Each sync **deletes only
`vibecut__*` files** then rewrites the fresh set, so:

- your own hand-authored prompts and `README.txt` are never touched;
- do **not** name your own prompts with the `vibecut__` prefix (reserved);
- the `"vibecut"` tag is for display/hide only — it is **never** the deletion
  selector (a user prompt that happens to carry a `vibecut` tag is safe).

The write is a single MainActor batch (delete + write + one rescan), so N prompts
produce exactly **one** `prompt_library` broadcast — no per-file flap on the phone.

## Wire protocol

- `sync_vibecut` (iPhone → Mac, `SyncVibeCutMessage`) — trigger a re-sync.
- `sync_vibecut_ack` (Mac → iPhone, `SyncVibeCutAckMessage`) — `syncedCount`,
  `skippedCount`, `error?`. The refreshed catalog itself rides the normal
  `prompt_library` broadcast; the ack is just the count/reason signal.

On repo-not-found (or a valid-but-empty read) the Mac leaves the existing
inherited set **untouched** and acks `syncedCount: 0` with a reason
(`"VibeCut repo not found at <path>"`). The same holds for a catalog whose
`version` major is above 3 or does not parse (`"VibeCut catalog version <v> is
newer than this Quip understands"`); a catalog with no `version` is read as
legacy (Q-81).

## On the phone

- Settings → Prompts → tap the ⟳ **Sync from VibeCut** button (enabled only when
  connected + authed). The header shows a transient "N synced" / error.
- Inherited rows carry a quiet **VibeCut** badge, merged into the one list.
- **Hide model:** swipe a row → Hide/Show. Hidden prompts are dropped from the
  paste / quick-picker but stay visible-but-dimmed (with a **Hidden** badge) in
  the settings editor so you can re-enable them. Hidden state is phone-local
  (`hiddenPromptIDsJSON`) and pruned when a prompt leaves the catalog.
- Editing an inherited prompt keeps its `vibecut` tag (badge survives), but the
  next Sync re-lands the VibeCut version — prefer Hide over Edit/Delete for
  inherited prompts.

## Source references

- Pure mapping + include filter + id stability: `Shared/VibeCutPromptMapper.swift` (`map(catalog:knownIDs:)`); id map file: `QuipMac/Services/VibeCutSyncService.swift`
- Hide-state helpers: `Shared/PromptHideState.swift`
- Wire messages: `Shared/MessageProtocol.swift` (`SyncVibeCut*`, `PromptEntry.isInherited`)
- Mac reader + batch writer + handler: `QuipMac/Services/VibeCutPromptReader.swift`,
  `QuipMac/Services/PromptLibrary.swift` (`replaceVibeCutSet`), `QuipMac/QuipMacApp.swift`
- iOS UI: `QuipiOS/QuipApp.swift` (`PromptLibrarySheet`), `QuipiOS/Services/WebSocketClient.swift`
