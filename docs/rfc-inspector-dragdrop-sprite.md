# RFC: Drag-drop sprite picker (#143)

Status: Draft — design phase. No code changes yet.
Owner: labelle-gui.
Tracks: issue [#143](https://github.com/labelle-toolkit/labelle-gui/issues/143).
Last updated: 2026-05-18.

## Status quo

The Sprite component inspector renders a single text input for `sprite_name`:

- `src/modules/inspector/sprite.zig` — `inputText("sprite_name", ...)` with a soft red `(missing)` hint when the typed key doesn't resolve against `atlas.Index.by_name` (PR #104).
- The user has to type the atlas key exactly. TexturePacker keys mirror the *source PNG's relative path*, e.g. `refectory/refectory_table.png` — not just a basename, and not visible anywhere in the editor UI today.
- The project tree (`src/modules/project_tree.zig`) shows the file tree under `<project>/`. It surfaces source files (PNGs under `assets/`) and atlas manifests (JSONs under `resources/`), but neither carries any indication of what sprite keys the engine accepts. The user has to read TexturePacker output files by hand to discover them.

The atlas data model (`src/atlas.zig`):

- `Index.atlases: ArrayList(Atlas)` — one per `Resource` in `project.labelle`.
- Each `Atlas` carries a `name` (the resource name from config), `texture_id` (GL texture), and a `frames: StringHashMap(Frame)` mapping sprite key → rect-in-sheet.
- `Index.by_name` is the flat lookup all callers use to validate keys.

So the editor *already knows* every valid sprite key — it just doesn't expose them to the user.

## Goals

1. Let the user pick a sprite by **dragging a tree entry** onto the `sprite_name` input.
2. Make every valid sprite key in the loaded atlases **discoverable from the project tree**, including keys packed inside multi-sprite manifests.
3. Make invalid drops **impossible at the source**: only tree entries we know how to resolve are draggable. No post-drop `(missing)` surprises.
4. Keep the existing manual-typing path working unchanged.
5. Work in **both editors** — scene tab and prefab tab — without duplicating the drop-target logic.

## Non-goals

1. **OS-level file drop** (drag from Finder / Explorer into the editor). Different API surface; deferred.
2. **Reverse drag** (drag a Sprite component *out* of the inspector). Deferred.
3. **Drag-drop for non-sprite fields** (e.g. dragging a prefab onto a `prefab` field). Sensible follow-up.
4. **Search-as-you-type sprite picker dropdown.** Different UX angle on the same gap; can ship in parallel.
5. **Editing the atlas itself** (renaming keys, repacking). Out of scope.
6. **Multi-sprite drag** (selecting many tree entries and dropping a batch). Single-key per drop.

## Design

### Two-part change

The drop side is small. The drag side is most of the work.

```
┌─ project_tree (drag source) ──────┐    ┌─ inspector/sprite (drop target) ─┐
│ resources/                        │    │                                  │
│   main_atlas.json   ▼             │    │ ▼ Sprite                         │
│     refectory/seat.png   ⋮ drag   │ →  │   ┌─────────────────┐ sprite_name│
│     refectory/table.png  ⋮ drag   │    │   │ refectory/seat..│ (target)   │
│     wall.png             ⋮ drag   │    │   └─────────────────┘            │
│ assets/                           │    │   bottom_left   ▼ pivot          │
│   refectory/seat.png  (not drag)  │    │   world          layer           │
└───────────────────────────────────┘    └──────────────────────────────────┘
```

Source-side PNGs are *inputs* to TexturePacker, not addressable by the engine, so they stay non-draggable. The atlas manifests under `resources/` expand into their constituent sprite keys; each key is a drag source.

### Drag payload

ImGui's drag-drop API ships a typed payload identifier (a short string up to 32 chars) plus an arbitrary byte buffer. Define one:

```zig
// in src/modules/dnd.zig
pub const PAYLOAD_TYPE: [:0]const u8 = "labelle_sprite_key";

pub const SpriteKeyPayload = struct {
    /// Length of the valid prefix of `key`. Up to PAYLOAD_KEY_CAP - 1.
    len: u8,
    /// Null-padded sprite key, owned for the duration of the drag.
    /// Sized to fit the longest realistic atlas key the project
    /// has shown so far (255 covers the flying-platform keys with
    /// headroom). Caller MUST NOT assume this matches the receiver's
    /// `sprite.sprite_name` capacity — the drop side clamps.
    key: [255:0]u8,
};
```

A fixed-size struct keeps the payload pointer-stable across the frame ImGui needs it. The drop side reads `payload.key[0..payload.len]` and clamps to its own field width before copying.

### Source side — project tree

Two structural changes to `project_tree.zig` + `tree_view.zig`:

1. **Atlas manifests expand inline.** For every JSON file under `resources/`, look up its `Atlas` in `app.atlas_index`. If matched, render the tree node as an expandable group; sub-entries are the atlas's `frames` keys, each rendered as a leaf with a sprite-icon glyph (or a `🖼` text glyph fallback). If the lookup misses (atlas failed to load), render the JSON as a plain leaf with a `(unparsed)` hint — same soft-warning shape as the inspector's `(missing)` hint.

2. **Drag sources on sprite-key leaves only.** Each sprite-key leaf wraps its `zgui.selectable` call in `zgui.beginDragDropSource` / `endDragDropSource`. Inside the source block, set the payload (the `SpriteKeyPayload` above) and render a small preview — the key name plus a sprite thumbnail if cheap to fetch.

Source files (PNGs under `assets/`, scripts, scenes, prefabs) are **not draggable**. Tree rendering for those is unchanged.

### Drop side — sprite inspector

In `inspector/sprite.zig`, immediately after the `sprite_name` `inputText`:

```zig
if (zgui.beginDragDropTarget()) {
    defer zgui.endDragDropTarget();
    if (zgui.acceptDragDropPayload(dnd.PAYLOAD_TYPE, .{})) |raw| {
        const p: *const dnd.SpriteKeyPayload = @alignCast(@ptrCast(raw.data));
        const key = p.key[0..p.len];
        // Clamp to the destination buffer minus one so a trailing
        // zero always fits. The payload buffer is sized larger than
        // any realistic sprite_name field in the component schema,
        // so this clamp is the safety net for a malformed payload
        // or a future schema shrink — not a routine path.
        const copy_len = @min(key.len, sprite.sprite_name.len - 1);
        @memset(&sprite.sprite_name, 0);
        @memcpy(sprite.sprite_name[0..copy_len], key[0..copy_len]);
        is_dirty.* = true;
    }
}
```

That's the whole drop. No validation needed — the source only set a payload it had already resolved against the atlas index. The `@min` guard prevents an out-of-bounds `@memcpy` if a future atlas emits a key longer than the field; the trailing `sprite_name.len - 1` reservation keeps room for the null terminator that the `inputText` path already relies on (`std.mem.sliceTo(&buf, 0)`).

### Where the new file lives

Drag-drop is a small concern shared by exactly two callers (project_tree, inspector/sprite). Putting the payload type + helpers in `src/modules/dnd.zig` keeps both sides talking to one definition:

```
src/
├── atlas.zig                      (existing)
├── modules/
│   ├── dnd.zig                    (new — payload type + helpers)
│   ├── project_tree.zig           (modified — atlas expansion + drag sources)
│   ├── inspector/
│   │   └── sprite.zig             (modified — drop target on sprite_name)
│   └── ...
└── ...
```

### Lifecycle / freshness

The `atlas.Index` is rebuilt when `ProjectManager.generation` changes (project open/close, resource list edit). Both the tree and the inspector already pull from `app.atlas_index` each frame, so a project switch naturally re-renders correct draggable sets with no extra plumbing.

If the atlas reloads *mid-drag* (an unlikely race — a Save-and-rebuild while the user holds the mouse button), ImGui's payload is a value copy held in the imgui context, not a pointer back into our memory. Reading `payload.key` post-rebuild stays valid; the only risk is that the dropped key no longer resolves on the next frame. Inspector's existing `(missing)` hint covers that case.

## Tree expansion details

Atlas manifests in `flying-platform-labelle` carry many sprites — empirically dozens to low hundreds per atlas. Three things follow:

- **Lazy expansion.** Render the atlas leaf collapsed by default; expand on user click. Don't iterate `frames` until ImGui actually opens the sub-tree.
- **No alphabetical sort.** TexturePacker's emission order is stable across reruns; preserve it so the user sees the same layout twice. Sorting would scramble the natural grouping.
- **Bounded display.** If an atlas has > 500 sprites, render the first 500 plus a `… (N more)` placeholder line. Configurable later if real projects need a search box inside the tree.

## Persistence

Nothing to persist. Drag-drop is purely interactive. No prefs entries, no project.labelle additions, no on-disk format changes.

## Test plan

### Unit

- `tests.zig` — new `SpriteDndTests` scope. Cover:
  - Payload struct round-trips through pack / unpack helpers.
  - Drop helper writes the key into a `sprite.sprite_name` buffer correctly, zero-padding the tail.
  - Truncation: a payload key whose length exceeds `sprite.sprite_name.len - 1` gets clamped, the destination buffer stays null-terminated, no panic.

### Integration / TE

- `gui_tests.zig` — drive a simulated drag from a known atlas-key node onto the `sprite_name` input; assert post-drop the field equals the dragged key. ImGui Test Engine exposes `ItemDragAndDrop` for this exact pattern.

### Visual

- Open `flying-platform-labelle/scenes/main.jsonc` → descend into `refectory_table` prefab → drag a key from the atlas expansion → drop on `sprite_name` → confirm the field updates and the `(missing)` hint disappears.
- Open `canteen` prefab → confirm same behavior in the prefab editor.
- Verify the source-side PNGs under `assets/` are *not* draggable (no drag indicator on hover).

## Open questions

1. **Icon vs text glyph for sprite-key leaves.** A 16×16 atlas thumbnail next to each key would be ideal. Cheap if we already have the GL texture loaded (we do — `Atlas.texture_id`), since we can `zgui.image` a sub-rect via UVs. The risk is performance with 500 leaves rendered. Mitigation: only render the thumbnail when the leaf is hovered or selected. **Recommendation:** ship without thumbnails in v1; add as a follow-up.

2. **Should we expose source PNGs differently** — e.g., gray-out, label `(not addressable)`? Discoverability vs noise tradeoff. **Recommendation:** leave them rendered as plain file leaves (no extra chrome). Users learn quickly that the atlas-key sub-tree is what they want.

3. **Drag from inspector "Prefab contents" tree?** The read-only Prefab contents section (PR #89) shows sprite names too. Making those draggable would feel consistent — but the intent there is "show what this prefab carries," not "pick a sprite." **Recommendation:** leave Prefab contents non-draggable. A separate ticket can revisit if users ask.

4. **Cross-tab drag.** Can the user drag from the tree in one window/instance into another? ImGui's drag-drop is single-context, single-window — no cross-context flow. Not a concern in practice.

5. **Tree node ID collisions.** Sprite keys are unique within one atlas, but two atlases could conceivably emit the same key (the atlas index already logs a "first-wins" warning when this happens). The tree currently uses path-based IDs; sprite leaves would need a composite ID like `<atlas_name>/<key>` to keep ImGui IDs unique. **Recommendation:** use the composite-ID form even though atlas-internal keys are unique, to future-proof against the collision case.

## Alternatives considered

### A. Any-file drag, validate-on-drop

Make every tree entry draggable; the inspector's drop handler runs the atlas lookup and either accepts or surfaces `(missing)`.

- ✅ Simpler tree-side code (no atlas expansion, no draggability filter).
- ❌ Users can spend the drag energy on a script file and get rejected. UX cliff.
- ❌ Source-side PNGs would suggest the wrong mental model — "I dropped the file the sprite came from, why does it say missing?"

Rejected. Drag-drop should never silently fail when the source UI made the drag look valid.

### B. Searchable dropdown picker next to the input

Replace `inputText` with a combo-style searchable picker enumerating every key in `atlas_index.by_name`.

- ✅ No tree changes needed.
- ✅ Discoverability is great (every key in one list).
- ❌ Doesn't match the spatial mental model a 2D editor reinforces. Users *see* sprites in the viewport; the tree is the natural place to pick them.
- ❌ Loses the "drag to where it goes" muscle memory from every other editor.

Rejected as the *primary* path. Could ship as a complementary affordance (typing into the existing `inputText` auto-completes from the index) in a follow-up.

### C. Floating "Asset Browser" panel

Add a third top-level panel listing every atlas + key, draggable, dockable.

- ✅ Decouples the asset list from the project-tree shape.
- ❌ One more panel to manage, dock, hide. Editor surface grows.
- ❌ Splits the user's attention — "is it in the tree or the browser?"

Rejected for v1. Worth revisiting if the editor grows non-sprite asset types (audio cues, fonts, shaders) that don't fit the file-tree model.

## Rollout

One PR; one branch (`feat/143-dragdrop-sprite`); one issue (#143).

Suggested commit shape:

1. `feat(dnd): payload type + helpers in modules/dnd.zig` — new file + tests, no UI changes yet.
2. `feat(project_tree): expand atlas manifests into draggable sprite keys` — tree-side change. Drag has no target yet; payload is wired but drops nowhere.
3. `feat(inspector/sprite): drop-target on sprite_name accepts atlas keys` — closes the loop.
4. `test(gui-test): TE coverage for tree→sprite_name drag` — TE integration test.
5. `docs: update CLAUDE.md "Source map" with new modules/dnd.zig entry`.

Each commit is independently sensible; landing them as a stacked sequence in one PR is fine, but a reviewer can also bisect cleanly.

## Risk

| Item | Severity | Mitigation |
|---|---|---|
| 500+ frames per atlas degrades tree rendering | Low | Lazy expansion + per-atlas bounded display caps the per-frame work to whatever's visible. Same shape ImGui itself uses for its own demo trees. |
| ImGui drag-drop payload pointer instability across `accept` calls | Low | The struct is fixed-size with no pointers; ImGui copies the bytes into its own buffer. Safe by construction. |
| Sprite key longer than `sprite.sprite_name` buffer panics `@memcpy` | Low | Drop side clamps `copy_len` to `sprite.sprite_name.len - 1` before the copy; the explicit `@memset` zero-fills the rest, preserving the null-terminator contract. Captured in the unit test plan. |
| Sprite keys with embedded NULs or non-UTF-8 bytes | Very low | TexturePacker emits valid UTF-8. We zero-pad on copy and use `sliceTo(&buf, 0)` on read like the existing `sprite_name` path does. |
| Atlas index rebuilt mid-drag | Very low | ImGui payload is value-copied; the drop side reads from its own buffer. Worst case: the dropped key fails the next `by_name.get`, surfacing the existing `(missing)` hint. No crash. |

## Approval / sign-off

- [ ] Owner sign-off (apotema or leonardomag31-lab).
- [ ] Open questions resolved (or explicitly punted to follow-ups).
- [ ] PR scaffolded as the rollout commit sequence.

Once signed, this RFC moves to "Accepted" and the implementation PR lands against `main`. Post-merge, this file stays in `docs/` as historical context — same convention as the Zig 0.16 migration RFC.

## Reviews

### 2026-05-18 — gemini-code-assist

The RFC is exceptionally well-structured and aligns perfectly with the labelle-gui architecture. Relying on the existing `app.atlas_index` to expand `resources/` JSONs and keeping the drag-and-drop state in a new `modules/dnd.zig` is the correct approach.

One adjustment requested: clamp the destination buffer in the drop-side snippet so a payload key longer than `sprite.sprite_name` can't panic `@memcpy`. The snippet in the Design section and the Test plan's truncation case have been updated accordingly (commit `<pending>`).

Items confirmed ready for implementation:

- Tree ID Collisions — composite IDs (`<atlas_name>/<key>`) approach is correct for ImGui.
- Lazy Expansion — essential for performance; ImGui trees with hundreds of always-submitted elements get heavy fast.
- Test Plan — using `gui_tests.zig` with the ImGui Test Engine's `ItemDragAndDrop` is the right verification path.
