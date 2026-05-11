# CLAUDE.md — labelle-gui

Guidance for Claude Code when working in this directory. See `../CLAUDE.md` for toolkit-wide context.

## What this app does

GUI editor for `labelle-toolkit` game projects. The editable artifact is a `project.labelle` ZON file at the project root (schema = `labelle-assembler`'s `ProjectConfig`). The gui scaffolds the project tree and drives `build` / `run` via the `labelle` CLI launcher — it does **not** generate `build.zig` / `build.zig.zon` / `main.zig` itself; the assembler (invoked by the launcher) owns those.

## Build commands

```bash
zig build           # build the gui exe
zig build run       # build + run the gui
zig build test      # zspec unit/filesystem tests (hermetic)
zig build gui-test  # ImGui Test Engine UI tests (hidden GLFW window)
zig build smoke     # end-to-end against the real `labelle` launcher — env-dependent
```

`zig build smoke` requires `labelle` on PATH and either a populated `~/.labelle/packages/` cache or network. It's the only test that proves the launcher integration actually works. Run it after touching `src/project.zig` or `src/compiler.zig`.

## Source map

| File | Role |
|------|------|
| `src/main.zig` | GLFW init, window + GL context, font + DPI setup, frame loop. Delegates per-frame UI to `App.renderFrame()`. Stays slim on purpose. |
| `src/app.zig` | `App` struct: owns `ProjectManager`, `Compiler`, `TreeView`, status bar, dialog state, and the `Module.Registry`. `App.renderFrame()` is the single function the test runner can call to drive the real UI. |
| `src/module.zig` | `Module` and `Registry` (issue #22). Modules expose a togglable panel; the Registry renders the View menu and dispatches `render_panel(*App)` for every open module. Each module's `is_open` points into App state so the menu toggle and the panel's `popen` flag are the same memory. |
| `src/modules/` | One file per togglable panel. Each exports `makeModule(*App) module.Module` and gets appended to `App.modules` in `App.init`. Current togglable panels: `compiler_output`, `project_settings`, `project_tree`, `resources`. The `scene` and `prefab` editors live here too but are *not* registered as togglable panels — they open as tabs via tree-click. `viewport.zig` and `inspector.zig` are shared widgets (not modules) used by both editors. |
| `src/dialogs/` | Modal popups — transient, not part of the Registry because they're not togglable panels. Each exports `pub fn render(*App) void` called once per frame from `App.renderFrame`. Current: `new_scene`, `dpi_warning`, `close_scene` (unsaved-tab confirmation). |
| `src/project.zig` | `ProjectConfig` (mirrors a subset of `labelle-assembler/src/config.zig:ProjectConfig`), `ProjectManager`, `project.labelle` read/write. Each `Project` owns an `ArenaAllocator` so the parsed config strings free uniformly in `deinit`. |
| `src/scene_io.zig` | JSONC scene/prefab loader + writer. Typed `Sprite` and `Position` components round-trip as managed fields; everything else is captured as verbatim `component_extras` / `TopLevelExtra` so unknown keys survive a save. `LoadedScene` and `LoadedPrefab` both own a parse arena. |
| `src/atlas.zig` | Per-project atlas index. Walks `ProjectConfig.resources`, parses each TexturePacker JSON, decodes the PNG via `zstbi`, uploads a GL texture, and folds all sprite names into one combined lookup. Owned by `App` and keyed by `ProjectManager.generation` — invalidated on project new/load/close. The inspector uses it to flag missing `sprite_name`; the viewport uses it to draw the real atlas frame as a textured quad. |
| `src/compiler.zig` | Wraps `labelle generate/build/run` as a child process. `syncProjectFiles` calls `ProjectManager.saveProject`. `buildOrRun` spawns; `pollBuild` waits and captures stdout/stderr. |
| `src/tree_view.zig` | Project tree widget. |
| `src/tests.zig` | zspec test root; covers `ProjectConfig`, `ProjectManager`, scaffold folders, save/load round-trip, `Compiler` state. |
| `src/gui_tests.zig` | UI test runner using zgui's bundled ImGui Test Engine (`with_te=true`). Constructs an `App` against a hidden window and drives it with `TestContext.menuAction(...)`. See "TE quirks" below. |
| `src/smoke.zig` | End-to-end smoke harness — temp dir, `ProjectManager.saveProject`, `Compiler.build`, asserts `.labelle/<target>/` appears. |

## Reference example project

`../flying-platform-labelle/` is the canonical real-world project the
toolkit is currently developed against. Look there for current `project.labelle`,
`scenes/*.jsonc`, prefab/component shapes, and resource manifests rather
than guessing or grabbing from older examples in this tree. The
assembler's `examples/` directory has stripped-down minimal projects for
each backend (`raylib`, `sokol`, etc.) that are also kept current.

## project.labelle pass-through

External projects (e.g. `../flying-platform-labelle/`) carry top-level
fields the gui doesn't model — `states`, `layers`, `plugins`, `gui`,
`ios`, `android`, `labelle_version`, `hidden`. On `loadProject`,
`extractUnmodeledFields` (a small ZON top-level scanner in `project.zig`)
captures the verbatim source text for each of those into `Project.extras`.
`renderProjectLabelle` re-emits them inside the closing `}` after the
managed fields, so external projects round-trip without data loss.

Known limitations of the pass-through:

- **Comments above managed fields** are dropped. Comments above
  unmodeled fields ride along with that field's verbatim block — the
  scanner captures the comment block as part of the field's text.
- **Multi-line strings (`\\...`)** and **`'...'` character literals**
  aren't handled because the assembler's schema doesn't use them. If
  either appears in a future schema, grow `scanValue` in `project.zig`.
- **Field order shifts** — managed fields are re-emitted first, then
  extras. Functionally equivalent but the file isn't byte-identical
  to its loaded form.

## Key invariants

1. **`project.labelle` must pin all four versions** — `core_version`, `engine_version`, `gfx_version`, `assembler_version`. The launcher's resolver falls back to its own version for missing fields (`labelle-cli/src/cli/cache.zig:29`: `cfg.assembler_version orelse cfg.labelle_version`), which 404s when CLI and assembler aren't lockstep. Defaults in `ProjectConfig` track `labelle-cli/versions.zon` and the CLI's own assembler pin.
2. **Project = directory.** `Project.dir` holds the project directory; `<dir>/project.labelle` is the editable file. Open / Save dialogs use `nfd.openFolderDialog`, not file dialogs.
3. **Don't reintroduce `build.zig` template generation.** The assembler owns that. If you find yourself writing build files from the gui, you're going the wrong direction.

## Editor tabs: scenes and prefabs

Editor tabs aren't togglable panels through the View menu. Instead:

- The user clicks a `.jsonc` file in the Project Tree → `project_tree`
  classifies it by directory (`isScenePath`/`isPrefabPath`) and routes
  it through `App.openScene(path)` or `App.openPrefab(path)` → a new
  `SceneState` or `PrefabState` is appended to `App.open_tabs`
  (wrapped in an `OpenTab` tagged union).
- The main content area renders a `TabBar` when `open_tabs.len > 0`;
  each tab's body comes from `OpenTab.render(app)`, which dispatches
  to `scene_mod.render` or `prefab_mod.render`.
- The × close button on a dirty tab opens `dialogs/close_scene.zig`
  (Save and close / Discard / Cancel) via `App.pending_close_idx`.
  The modal calls `OpenTab.save(app)` which dispatches by variant.
- Project transitions (`ProjectManager.generation` change) trigger
  `App.closeAllTabs` so the next frame doesn't read freed memory
  belonging to the old project.
- `OpenTab` has `displayName`, `path`, `isDirty`, `save`, `render`,
  `deinit` — the rest of `App` (tab strip, close modal, dedup on
  open) only goes through these, never inspects the variant.

Both `SceneState` and `PrefabState` carry their own arena (path +
display name) and own a `Loaded*` value (parsed-source arena from
`scene_io`). `deinit(allocator)` frees both.

Both editors have a two-column layout: viewport on the left, inspector
on the right. The shared `modules/viewport.zig` draws entity markers
on a pan/zoom canvas, handles hit-test, and drives drag-to-move; the
shared `modules/inspector.zig` renders one entity's editable surface.
Both take an optional `*const atlas.Index` so they can resolve typed
`Sprite` components against the active project's atlases: the viewport
draws the resolved frame as a textured quad with pivot-aware placement
(falling back to a coloured marker plus a `?` overlay when a Sprite is
declared but unresolved), and the inspector shows a `(missing)` hint
next to `sprite_name` when the index can't find it. World +y is up
(Y-axis flipped from screen space).

- Scene tab → viewport operates on `loaded.scene.entities`.
- Prefab tab → viewport operates on `loaded.children` (sub-entities
  with their own Position + components — e.g. hydroponics room tiles
  drag-to-move). The prefab's own components live on `loaded.entity`;
  when nothing is selected in the viewport the inspector shows them,
  otherwise it shows the selected child.

Sub-entities nested inside a component value (e.g. `Room.workstations`)
ride along as part of the parent component's verbatim extras — not
modeled structurally. Editing them means hand-editing the file (or
extending the gui's component understanding later).

## Adding a new module

1. Create `src/modules/<name>.zig` with `pub fn makeModule(app: *App) module.Module`. Return `.is_open = &app.<field>` (state lives in `App`, not the module file) and `.render_panel = render` where `render(*App)` does its own `zgui.begin`/`end`.
2. Add a `bool` field to `App` for the panel's open state. Toggle it from menu actions or other code paths as needed.
3. Grow `App.modules: [N]Module` in `app.zig` and assign the new module's slot in `App.init`.
4. The View menu auto-builds from the Registry. The panel renders only when `is_open.*` is true.

## TE (Test Engine) quirks

When zgui is built with `with_te = true`:

- `zgui.init(allocator)` **already calls `zgui.te.init()`** (gui.zig:60). A second explicit `te.init()` double-registers the `TestEnginePerfTool` settings handler and trips an imgui assertion. Just use `zgui.te.getTestEngine()` to retrieve the engine zgui created.
- `engine.queueTests(.tests, "", .{})` matches nothing — the empty string filter falls through to "include nothing". Use the literal `"all"` to match every registered test (`imgui_test_engine/imgui_te_engine.cpp:1382`).

## Dep pinning notes

`build.zig.zon` pins the three zig-gamedev deps (`zgui`, `zglfw`, `zopengl`) to specific pre-Zig-0.16 commits. Upstream main moved to Zig 0.16 in early 2026; this project targets 0.15.2 (toolkit-wide). If you bump these, verify against:

- `zopengl` must not use `@Enum` (added when upstream switched to 0.16).
- `zglfw` 5-arg `createWindow` signature is what `main.zig:67` expects.
- `zgui` must predate the `0.16.x` branch merge. The current pin
  (`b6a4dff52`, 2026-03-05) includes upstream PR #88, which fixes the
  128-byte `g_ContextMap` leak warning that older pins logged at
  shutdown. If bumping zgui further, verify on 0.15.2 first.
