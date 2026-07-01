# Content share intake

Quip accepts sourced news links and text from other apps (nugget-expo,
FintechAdventures, or any share sheet) and turns them into a **reviewed prompt
draft** that the user sends to the currently selected Quip agent. Nothing is
sent automatically — the phone always shows a review sheet first.

There are two ingress paths that both land in the same
[`ContentShareDraft`](../Shared/ContentShareDraft.swift) schema:

1. **`quip://share` deep link** — lightweight, URL-only. Good for a link + a
   line of context from a share sheet, an email, or a push action.
2. **JSON envelope** — the full `ContentShareDraft` shape, for callers that
   carry claims, entities, and suggested uses (e.g. a Nugget SignalEnvelope).

Both decode into the same Swift type and render through the same
[prompt composer](../Shared/ContentSharePromptComposer.swift).

---

## `quip://share` URL format

```
quip://share?title=<t>&url=<u>&summary=<s>&source=<l>&shareUrl=<h>&sourceApp=<a>&sourceRecordId=<r>&mode=<m>
```

### Query parameters

| Param            | Maps to `ContentShareDraft` field | Required | Notes |
|------------------|-----------------------------------|----------|-------|
| `title`          | `title`                           | see note | Falls back to `url` if omitted. |
| `url`            | `sourceUrl`                       | see note | The canonical article/source link. |
| `summary`        | `summary`                         | no       | One or two lines of context. |
| `source`         | `sourceLabel`                     | no       | Display label, e.g. `Reuters`, `ACA International`. |
| `shareUrl`       | `shareUrl`                        | no       | Alternate/tracking share link; kept alongside `sourceUrl`. |
| `sourceApp`      | `sourceApp`                       | no       | Originating app id, e.g. `nugget-expo`. |
| `sourceRecordId` | `sourceRecordId`                  | no       | Caller's record id for round-tripping. |
| `mode`           | prompt mode                       | no       | One of `summarize`, `augment_for_nugget`, `draft_followup`. Defaults to `summarize`. |

**At least one of `title` or `url` must be present** — a link with neither
classifies as a no-op (`.none`) and is silently ignored. It never changes the
selected window or opens the text input.

Fields the URL path does **not** carry (`entities`, `claims`, `suggestedUses`,
`publishedAt`, `createdAt`, `schemaVersion`) default to empty/`nil`. Use the
JSON envelope path when you need them.

### Encoding rules

- Percent-encode every query value per RFC 3986. Values are UTF-8 and
  percent-decoded by `URLComponents`, so spaces (`%20`), ampersands (`%26`),
  and Unicode all round-trip.
- **An `&` inside a value MUST be `%26`** or it will be read as a parameter
  separator and truncate the value.
- Empty query values are dropped (a present-but-empty param is treated as
  absent).
- Percent-decoding handles spaces, ampersands, and Unicode in `title` and
  `summary`.

### Example links

**nugget-expo** — a watched-firm news nugget:

```
quip://share?sourceApp=nugget-expo&sourceRecordId=nugget_8f21&title=ACA%20International%20flags%20new%20FDCPA%20guidance&url=https%3A%2F%2Fexample.com%2Faca-fdcpa&source=ACA%20International&summary=New%20guidance%20tightens%20consumer%20contact%20windows.&mode=augment_for_nugget
```

**FintechAdventures** — a shared market item routed to a draft follow-up:

```
quip://share?sourceApp=fintechadventures&title=Card%20network%20fees%20rise%20in%20Q3&url=https%3A%2F%2Fexample.com%2Fcard-fees&source=FintechAdventures&mode=draft_followup
```

### Coexisting routes (do not break)

`quip://share` is classified by the shared
[`ContentShareDeepLink`](../Shared/ContentShareDeepLink.swift) router alongside
the existing routes. All of these keep their behavior:

- `quip://pair?url=…&pin=…` — tap-to-pair
- `quip://perms` — open settings/permissions
- `quip://window/<id>` and legacy `quip://<windowId>` — select a window + open
  the text input

A malformed `quip://share` link resolves to `.none` — a no-op that does not
touch `selectedWindowId` or open the text input.

---

## JSON envelope (SignalEnvelope-compatible shape)

Callers that carry structured intelligence encode a JSON object using the exact
`ContentShareDraft` field names (deterministic camelCase, decodable by any
non-Swift app):

```json
{
  "schemaVersion": 1,
  "sourceApp": "nugget-expo",
  "sourceRecordId": "nugget_8f21",
  "title": "ACA International flags new FDCPA guidance",
  "summary": "New guidance tightens consumer contact windows.",
  "sourceUrl": "https://example.com/aca-fdcpa",
  "sourceLabel": "ACA International",
  "shareUrl": "https://nugget.example/s/8f21",
  "publishedAt": "2026-06-30T14:00:00Z",
  "entities": ["ACA International", "FDCPA"],
  "claims": [
    {
      "text": "Contact windows narrow to 8am–8pm local.",
      "sourceUrl": "https://example.com/aca-fdcpa",
      "status": "verified",
      "note": "Primary source, dated 2026-06-30."
    }
  ],
  "suggestedUses": [
    "Brief the compliance channel",
    "Draft a client FAQ update"
  ],
  "createdAt": "2026-06-30T15:00:00Z"
}
```

### Envelope → `ContentShareDraft` mapping

A Nugget **SignalEnvelope** maps 1:1 onto this shape:

| SignalEnvelope concept        | `ContentShareDraft` field |
|-------------------------------|---------------------------|
| Originating app / integration | `sourceApp`               |
| Envelope / record id          | `sourceRecordId`          |
| Headline                      | `title`                   |
| Abstract / lede               | `summary`                 |
| Canonical link                | `sourceUrl`               |
| Publisher name                | `sourceLabel`             |
| Share/tracking link           | `shareUrl`                |
| Publish timestamp             | `publishedAt`             |
| Named entities                | `entities` (array)        |
| Source-backed claims          | `claims` (array)          |
| Recommended plays             | `suggestedUses` (array)   |
| Envelope creation time        | `createdAt`               |

Each claim maps to a
[`ContentClaim`](../Shared/ContentShareDraft.swift) with `text` (required) plus
optional `sourceUrl`, `status`, and `note`.

### Decode tolerance (versioning)

The schema is forward/backward tolerant so callers can evolve independently:

- **Minimal payloads** — `{"title": "...", "sourceUrl": "..."}` decode fine;
  optional strings default to `nil`, optional arrays default to `[]`.
- **Missing `schemaVersion`** — defaults to the current version
  (`ContentShareDraft.currentSchemaVersion`).
- **Unknown extra fields** — ignored, so adding envelope fields never breaks an
  older Quip build.

---

## Prompt modes

The reviewed draft is rendered by
[`ContentSharePromptComposer`](../Shared/ContentSharePromptComposer.swift) into
a prompt with `Source`, `Context`, `Claims`, `Suggested uses`, and
`Requested action` sections. Empty sections are omitted; source attribution
(`Source URL` / `Share URL`) is never dropped. Output is **deterministic** for
the same draft + mode (no current-date dependency).

| Mode                 | Requested action |
|----------------------|------------------|
| `summarize`          | Tight summary that preserves attribution and flags anything unverified. |
| `augment_for_nugget` | Sales-ready Nugget context: **buyer angle**, **reusable claims**, **asset gaps**, **next best action**. |
| `draft_followup`     | A concise, source-grounded follow-up message ending with a clear next step. |

Example `summarize` output for the JSON envelope above:

```
Source:
Title: ACA International flags new FDCPA guidance (ACA International)
Source URL: https://example.com/aca-fdcpa
Share URL: https://nugget.example/s/8f21
Published: 2026-06-30T14:00:00Z

Context:
New guidance tightens consumer contact windows.
Entities: ACA International, FDCPA

Claims:
- Contact windows narrow to 8am–8pm local. [verified] (https://example.com/aca-fdcpa) — Primary source, dated 2026-06-30.

Suggested uses:
- Brief the compliance channel
- Draft a client FAQ update

Requested action:
Summarize the content above in a few tight sentences. Preserve the source attribution and flag anything that is unverified.
```

---

## Privacy rules

External share intake is deliberately narrow. Callers and integrations MUST
follow these rules:

- **Source-backed claims only.** Every claim carries a `sourceUrl` (or a
  `status`/`note` documenting provenance). Do not inject unsourced assertions.
- **User review before send.** A shared draft always opens the review sheet.
  Nothing reaches an agent until the user picks a window and taps Send.
- **No automatic public publishing.** Quip never posts, DMs, or forwards a
  draft anywhere on its own. The only action is sending the composed prompt to
  the user's own selected terminal.
- **No hidden CRM context in external share drafts.** Do not embed private
  contact records, account internals, or other CRM PII in the shared payload.
  Share the public, source-backed content only.

---

## Manual simulator verification

To verify the end-to-end flow (open a `quip://share` link → review → send to a
terminal) in the iOS Simulator:

1. Build and install the iOS app on a booted simulator:
   ```bash
   xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
     -derivedDataPath QuipiOS/build build
   xcrun simctl install booted \
     QuipiOS/build/Build/Products/Debug-iphonesimulator/Quip.app
   xcrun simctl launch booted com.quip.QuipiOS
   ```
2. Connect the app to a running Quip Mac/Linux instance so at least one window
   is visible and the connection indicator is live.
3. Open a share link (the simulator routes `openurl` to the app):
   ```bash
   xcrun simctl openurl booted \
     'quip://share?title=ACA%20International%20flags%20new%20FDCPA%20guidance&url=https%3A%2F%2Fexample.com%2Faca-fdcpa&source=ACA%20International&summary=New%20guidance%20tightens%20consumer%20contact%20windows.&mode=augment_for_nugget'
   ```
4. Confirm the **review sheet** appears with the title, source label, summary,
   source URL, the mode picker (defaulting to the link's `mode`), and a
   Send-to window picker.
5. Pick a window, tap **Send**, and confirm the composed prompt lands in that
   terminal exactly like a typed prompt. The sheet dismisses and the target
   window stays selected.
6. Verify no-op safety: `xcrun simctl openurl booted 'quip://share'` (no
   params) does nothing — no sheet, no window change.

> Deep-link routing and prompt composition are covered by the
> `ContentShareDeepLinkTests`, `ContentSharePromptComposerTests`,
> `ContentShareReviewStateTests`, and `ContentShareSendTests` suites; the steps
> above are the manual visual pass on top of those gates.
