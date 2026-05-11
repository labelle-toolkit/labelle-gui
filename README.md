# labelle-gui

Desktop GUI for authoring [labelle-toolkit](https://github.com/labelle-toolkit) game projects.

Edits `project.labelle`, scaffolds the project tree, and drives the `labelle` CLI launcher to generate / build / run the project.

## Requirements

- Zig 0.15.2
- The [`labelle` CLI](https://labelle.games) on PATH (install via `curl -fsSL https://labelle.games/install.sh | bash`)

## Build

```bash
zig build         # build the gui binary into zig-out/bin/labelle-gui
zig build run     # build and launch the gui
```

## Tests

```bash
zig build test       # zspec unit + filesystem tests (hermetic, ~42 tests)
zig build gui-test   # ImGui Test Engine UI tests (runs in a hidden GLFW window)
zig build smoke      # end-to-end integration check against the real `labelle` launcher
```

### `zig build smoke`

Drives the gui's own `project.zig` and `compiler.zig` against the installed `labelle` launcher: writes a temp project, runs `labelle generate` and `labelle build`, asserts `.labelle/<backend>_<platform>/` appears and the build succeeds. **Not** part of `zig build test` because it requires `labelle` on PATH and either a populated `~/.labelle/packages/` cache or network access to fetch packages.

Run it whenever changes touch `src/project.zig` (project.labelle schema) or `src/compiler.zig` (launcher invocation).

## How it talks to the rest of the toolkit

The gui doesn't generate `build.zig`, `build.zig.zon`, or `main.zig` itself. It writes a `project.labelle` (ZON, schema-compatible with `labelle-assembler`'s `ProjectConfig`) and shells out to the `labelle` launcher, which prims the package cache, resolves the right `labelle-assembler` binary, runs codegen, and runs `zig build`.

Version pins (`core_version`, `engine_version`, `gfx_version`, `assembler_version`) are required fields on the project file — without `assembler_version` the launcher falls back to its own version when fetching the assembler binary, which 404s if the CLI and assembler aren't in lockstep. Defaults in `src/project.zig` match `labelle-cli/versions.zon` + the CLI's `build.zig.zon` assembler pin.

## Project layout

```
src/
  main.zig                       # GLFW + zgui setup, swaps frame loop into App.renderFrame
  app.zig                        # App struct: per-instance state + per-frame rendering
  module.zig                     # Module + Registry — togglable panels and View menu (issue #22)
  modules/
    compiler_output.zig          # Bottom-dock compiler output panel
    project_settings.zig         # Edit ProjectConfig fields and persist via ProjectManager
    project_tree.zig             # Project sidebar (file tree)
    resources.zig                # Edit `resources` block (sprite atlases)
    scene.zig                    # Scene editor (per-tab state; opens via tree click, not View menu)
  dialogs/
    new_scene.zig                # New Scene modal + scene-file writer
    dpi_warning.zig              # One-shot DPI-changed warning modal
    close_scene.zig              # Unsaved-scene "Save and close / Discard / Cancel" modal
  project.zig                    # ProjectConfig, ProjectManager, project.labelle ZON I/O
  scene_io.zig                   # JSONC scene loader (used by modules/scene.zig)
  compiler.zig                   # Launches `labelle generate/build/run` and polls the child
  tree_view.zig                  # Project tree view widget
  config.zig                     # UI constants
  icons.zig                      # FontAwesome icon codepoints
  tests.zig                      # zspec test entry point
  gui_tests.zig                  # ImGui Test Engine harness (gui-test target)
  smoke.zig                      # End-to-end launcher integration check (smoke target)
```
