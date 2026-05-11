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
| `src/main.zig` | GLFW + zgui main loop; menu and dialog handling. State lives inline; Phase 2 of the TE work will refactor this into an `App` struct. |
| `src/project.zig` | `ProjectConfig` (mirrors a subset of `labelle-assembler/src/config.zig:ProjectConfig`), `ProjectManager`, `project.labelle` read/write. Each `Project` owns an `ArenaAllocator` so the parsed config strings free uniformly in `deinit`. |
| `src/compiler.zig` | Wraps `labelle generate/build/run` as a child process. `syncProjectFiles` calls `ProjectManager.saveProject`. `buildOrRun` spawns; `pollBuild` waits and captures stdout/stderr. |
| `src/tree_view.zig` | Project tree widget. |
| `src/tests.zig` | zspec test root; covers `ProjectConfig`, `ProjectManager`, scaffold folders, save/load round-trip, `Compiler` state. |
| `src/gui_tests.zig` | UI test runner using zgui's bundled ImGui Test Engine (`with_te=true`). See "TE quirks" below. |
| `src/smoke.zig` | End-to-end smoke harness — temp dir, `ProjectManager.saveProject`, `Compiler.build`, asserts `.labelle/<target>/` appears. |

## Key invariants

1. **`project.labelle` must pin all four versions** — `core_version`, `engine_version`, `gfx_version`, `assembler_version`. The launcher's resolver falls back to its own version for missing fields (`labelle-cli/src/cli/cache.zig:29`: `cfg.assembler_version orelse cfg.labelle_version`), which 404s when CLI and assembler aren't lockstep. Defaults in `ProjectConfig` track `labelle-cli/versions.zon` and the CLI's own assembler pin.
2. **Project = directory.** `Project.dir` holds the project directory; `<dir>/project.labelle` is the editable file. Open / Save dialogs use `nfd.openFolderDialog`, not file dialogs.
3. **Don't reintroduce `build.zig` template generation.** The assembler owns that. If you find yourself writing build files from the gui, you're going the wrong direction.

## TE (Test Engine) quirks

When zgui is built with `with_te = true`:

- `zgui.init(allocator)` **already calls `zgui.te.init()`** (gui.zig:60). A second explicit `te.init()` double-registers the `TestEnginePerfTool` settings handler and trips an imgui assertion. Just use `zgui.te.getTestEngine()` to retrieve the engine zgui created.
- `engine.queueTests(.tests, "", .{})` matches nothing — the empty string filter falls through to "include nothing". Use the literal `"all"` to match every registered test (`imgui_test_engine/imgui_te_engine.cpp:1382`).

## Dep pinning notes

`build.zig.zon` pins the three zig-gamedev deps (`zgui`, `zglfw`, `zopengl`) to specific pre-Zig-0.16 commits. Upstream main moved to Zig 0.16 in early 2026; this project targets 0.15.2 (toolkit-wide). If you bump these, verify against:

- `zopengl` must not use `@Enum` (added when upstream switched to 0.16).
- `zglfw` 5-arg `createWindow` signature is what `main.zig:67` expects.
- `zgui` must predate the `0.16.x` branch merge.
