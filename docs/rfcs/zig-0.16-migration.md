# RFC: Zig 0.15.2 → 0.16 Migration (labelle-toolkit)

Status: Draft — research phase. No code changes proposed yet.
Owner: labelle-gui (current PR), but the work spans the toolkit cluster.
Last updated: 2026-05-13.

## Status quo

All locally-present Zig repos pin `minimum_zig_version = "0.15.2"` and CI installs Zig 0.15.2 via `mlugg/setup-zig@v2` (the gui's `release.yml` lags at 0.15.1 — bug, see Open Questions).

| Repo | Zig pin | `minimum_zig_version` | CI version | Notes |
|---|---|---|---|---|
| `labelle-cli` v1.37.0 | 0.15.2 | `0.15.2` | `0.15.2` (ci.yml + release.yml) | Pulls `labelle-assembler` 0.8.0 as a Zig package dep from GitHub (`1c24f303586c…`). Statically links stb_image C source. |
| `labelle-engine` v1.35.0 | 0.15.2 | `0.15.2` | `0.15.2` (ci.yml, mobile-build.yml) | Path-dep on `../labelle-core` **(NOT PRESENT LOCALLY)**. Sub-pkgs `scene/` and `jsonc/` each have their own `build.zig.zon`. Uses `std.json.Stringify.valueAlloc` (0.15-namespace). |
| `labelle-fsm` v0.2.0 | 0.15.2 | `0.15.2` | no CI workflow checked in | Pulls `labelle-core` v1.4.0 by tag (`https://…/v1.4.0.tar.gz`). |
| `labelle-gfx` v1.10.0 | 0.15.2 | `0.15.2` | `'0.15.2'` (coverage.yml only — no CI workflow) | Path-dep on `../labelle-core` **(NOT PRESENT LOCALLY)**. Three sub-pkgs: `spatial_grid/`, `tilemap/`, `camera/`. |
| `labelle-gui` v0.1.0 | 0.15.2 | _none declared_ | `0.15.2` (ci.yml) / **`0.15.1` (release.yml — drift)** | The heavy hitter: 6 deps, including all four zig-gamedev pre-0.16 pins. |
| `labelle-imgui` v0.1.0 | 0.15.2 | `0.15.2` | none | Pulls `floooh/dcimgui` (`4557d7526fdd…`). Has Sokol + Raylib bridge sub-projects. |
| `flying-platform-labelle` v? | 0.15.2 | (uses CLI-driven build; no top-level `build.zig.zon`) | `0.15.2` (ci.yml, deploy-pages.yml) | Eight plugin sub-projects under `libs/*` each pin `minimum_zig_version = "0.15.2"`. Goes through `labelle` CLI launcher; assembler pin `0.3.0` lives in `project.labelle`. |
| `labelle.games` | n/a (Astro/TypeScript) | n/a | n/a | Marketing site. Not affected. |

Repos referenced but **not present locally**:
- `labelle-core` — every Zig repo here either path-deps it (`../labelle-core`) or URL-fetches it (`labelle-fsm` pins `v1.4.0`, `labelle-cli` pulls it transitively via `labelle-assembler`). Engine and gfx will not build until it is cloned or substituted.
- `labelle-assembler` — `labelle-cli`'s `build.zig.zon` URL-fetches it (`1c24f303586c…` = v0.8.0). Not editable locally. CLI 1.37.0 owns the assembler pin; bumping the assembler is gated on a CLI release.

That second bullet matters for the rollout plan: the chain is **assembler → CLI → flying-platform** (which invokes `labelle build`), so the toolkit cannot be fully validated until `labelle-assembler` is also on 0.16 upstream and a new CLI cuts a release pinning it.

## Why upgrade (and why not)

**Pros**
- Upstream zig-gamedev moved to Zig 0.16.0 across the board in Apr–May 2026 (`zglfw` PR #51 on 2026-04-22, `zopengl` PR #34 on 2026-05-02, `zstbi` PR #14 on 2026-05-11, `zgui` `9c0b41af12` on 2026-05-12). Staying on 0.15.2 means freezing those pins; we already cannot pull the DPI-scaling fix `zgui#102` (2026-05-12) or anything past it.
- `zgui` v0.16 ships PR #98 (more ImPlot bindings), PR #99 (build fixes), PR #88 (the `g_ContextMap` leak fix we already pulled), plus all the Vulkan-SDL3 / DX12 backend work — broadens our backend choices.
- `zopengl` v0.16 introduces the `@Enum` reflection helper and adds typed wrappers for OpenGL 4.0–4.6 functions (PR #30) which the viewport's GL upload path will eventually want.
- 0.16 stdlib changes (new `Io` abstraction, unified `ArrayList`, `std.json` re-namespacing) are cumulative — every cycle we delay makes the migration patch larger.

**Cons**
- 0.16 toolchain churn is wide: stdlib `Io` rewrite, ArrayList unification, `std.fs.File.readToEndAlloc` removal, `std.json.Stringify` namespace move. We touch all of these.
- `zspec` (used by gui, cli, engine.jsonc) does **not** yet have a 0.16 commit. The most recent commit is `e19d2893cb` (2026-05-05, "bump version to 0.8.0", on 0.15.2). Either we patch + fork zspec or we wait. **Blocking** unless we self-host.
- `labelle-core` is missing locally and `labelle-assembler` is upstream-only — we cannot validate the full launcher-driven build chain from this cluster alone.
- nfd-zig: last commit `031b6b08c2` (2026-04-08) is build-fix vintage; no explicit 0.16 callout. Needs verification.

**What forces the issue**
- The `with_node_editor` + `with_te` feature set we depend on lives only on a `zgui` revision we want to keep tracking; we already pinned to `b6a4dff52` to pull PR #88. Upstream is moving away from us.
- The gui PR work currently in flight already references files that exercise the GL path heavily (`atlas.zig`, `viewport.zig` rendering textured quads). Future bindings work (Vulkan backend, ImPlot growth, DX12) presupposes 0.16.

## What changes between 0.15.2 and 0.16

Categorised. Each item is annotated with whether the toolkit actually hits it and where.

### Build-system API

| Change | Used here? |
|---|---|
| `b.path(…)`, `b.dependency(…)`, `b.addModule(…)`, `b.addExecutable(.{ .root_module = b.createModule(…) })` | **Yes, everywhere** — `labelle-gui/build.zig`, `labelle-engine/build.zig`, `labelle-gfx/build.zig`, `labelle-cli/build.zig`. The "root_module = createModule" shape is already the 0.15.2 form and remains valid in 0.16. No action expected. |
| `b.addTest(.{ .root_module = b.createModule(…) })` with `.imports` array of `.{ .name, .module }` | **Yes** — `labelle-gui/build.zig:83`, `labelle-engine/build.zig:67`, etc. Same shape both versions; no action. |
| Custom `test_runner: .{ .path = …, .mode = .simple }` | **Yes** — `labelle-gui/build.zig:98` (zspec runner). zspec needs 0.16 work before this compiles. |
| `b.addCSourceFile` / `addIncludePath` / `link_libc = true` on `root_module` | **Yes** — `labelle-cli/build.zig:41-46`, `labelle-cli/build.zig:73-78` (stb_image impl). Same shape on 0.16. |
| `.win32_manifest = b.path(…)` on an executable | **Yes** — `labelle-gui/build.zig:67`. Same shape on 0.16. |

### Stdlib: `ArrayList` unification

`std.ArrayList(T)` (managed, carries its own allocator) was retired in 0.16; the unmanaged variant became the only `ArrayList`. The 0.15.2 pattern `std.ArrayList(T) = .{}` (which already meant "empty unmanaged-style state" after the 0.15 cleanup) still compiles but the call sites that pass the allocator-free `.append(v)` / `.deinit()` shape will need `.append(allocator, v)` / `.deinit(allocator)` everywhere.

The code already mixes both styles — most call sites already pass the allocator (`app.zig:263`, `app.zig:312`, `atlas.zig:91`, `tests.zig:2396`). The risk is in the corners.

**Definitely-managed-style usages (passing no allocator):** I did not find any in `labelle-gui/src/` — the cluster appears to have already done the unmanaged conversion. Verify per-repo before the bump.

**Counts of `= .{}` empty-init ArrayLists (toolkit total):** 45 managed-form sites + 13 explicit `Unmanaged` + 5 `(T){}` parenthesised. Mass `.empty` rename is a one-shot sed.

| Pattern | File:line | Action |
|---|---|---|
| `std.ArrayList(T) = .{}` | `labelle-gui/src/app.zig:144` (`open_tabs`), `src/app.zig:260` (`resources`), `src/scene_io.zig:379,864,1045,…`, `src/gizmo_io.zig:109`, `src/project.zig:342,423`, `src/flows/projector.zig:36-46`, `src/flows/renderers.zig:116,178,557` — and 30-odd more across the toolkit. | Rename initialiser to `.empty` (or leave `.{}` — both still compile in 0.16, but `.empty` is the new convention). Verify each call site already passes the allocator to `.append`/`.deinit`. |
| `std.ArrayListUnmanaged(T)` references | `labelle-gui/src/atlas.zig:60`, `src/gizmos.zig:104,110`, `src/tree_view.zig:316`, `labelle-engine/src/preview_mode.zig:161`, `src/game/gizmo_draws.zig:14`, … | In 0.16, `ArrayListUnmanaged` is a deprecated alias for `ArrayList`. **Rename eagerly to plain `std.ArrayList(T)` as part of the bump.** Even though the alias still compiles, it emits a deprecation warning. CI doesn't treat warnings as errors today, but landing a clean rename in the same PR avoids retrofitting later when we do tighten warning policy. |

### Stdlib: `std.Io` rewrite (Reader/Writer)

This is the biggest 0.16 stdlib change: `std.io.GenericReader`/`GenericWriter`/`AnyReader`/`AnyWriter` were replaced by an interface-style `std.Io.Reader` / `std.Io.Writer` with explicit buffer ownership.

| Pattern | File:line | Action |
|---|---|---|
| `file.readToEndAlloc(allocator, max)` | `labelle-gui/src/prefs.zig:86`, `src/compiler.zig:102-103,167-168`, `src/tests.zig:1774,1834,1986,2067,2106`, `src/modules/flow.zig:134`; `labelle-engine/src/atlas.zig:543`, `src/jsonc/prefab_cache.zig:68`, `src/jsonc/scene_loader.zig:233`; `labelle-cli/src/cli/bake.zig:86` | Replaced in 0.16 by `std.fs.File.deprecatedReader().readAllAlloc(allocator, max)` or, idiomatically, `std.fs.File.readToEndAllocOptions(…)` + an explicit `Io.Reader.allocRemaining(reader, allocator, .limited(max))`. Pick one helper and centralise. Most call sites already capture the file then immediately read — refactor opportunity. |
| `std.fs.cwd().readFileAlloc(allocator, path, max)` | `labelle-gui/src/atlas.zig:191`, `src/gizmo_io.zig:56` | Same name on 0.16, signature unchanged. No action. |
| `file.writeAll(bytes)` | ubiquitous (`labelle-gui/src/{prefs,project,scene_io,gizmo_io}.zig`, smoke.zig, tests.zig) | Still works on 0.16 directly on `File`. Watch for indirect callers that go through `file.writer()`. |
| `file.writer()` / `file.reader()` | **Not used** in `labelle-gui/src/` (verified). | No action needed in the gui. Re-verify the engine. |
| Writer parameters (e.g. `fn renderProjectLabelle(w: anytype, …)`) — `try w.writeAll(…)` | `labelle-gui/src/project.zig:427-465`, `src/scene_io.zig:383-…`, `src/gizmo_io.zig:113-143` | These use `anytype` writers; if all upstream callers stay on `*std.ArrayList(u8)` (managed-style `appendSlice`) or `*std.Io.Writer`, the duck-typed shape continues to work. The risk is where these helpers are passed a `File`'s writer (none here — they're called with ArrayList buffers, then `toOwnedSlice` + `writeAll`). |

### Stdlib: `std.json` namespace

| Pattern | File:line | Action |
|---|---|---|
| `std.json.Stringify.valueAlloc(alloc, value, .{})` | `labelle-engine/src/preview_mode.zig:433` | Moved in 0.16. Replacement is `std.json.stringifyAlloc(alloc, value, .{})` (verb-cased, no nested `Stringify` namespace). |
| `std.json.parseFromSlice(T, alloc, slice, .{ … })` | `labelle-gui/src/{preview,atlas,scene_io,gizmo_io,gizmos,tests,project,prefs}.zig` (15+ sites) | Same name in 0.16, same `ParseOptions`. No action. |

### Stdlib: `std.fs`

| Pattern | File:line | Action |
|---|---|---|
| `std.fs.cwd().openDir / createFile / openFile / makePath / deleteTree / makeDir` | many across `labelle-gui/src/{tests,smoke,project,prefs,atlas,gizmos,gui_tests,gizmo_io,modules/flow}.zig` | API stable through 0.16. The `.{}` open-option arg shape is preserved. No action. |
| `std.fs.openFileAbsolute / createFileAbsolute` | `labelle-gui/src/prefs.zig:75,154` | Stable. No action. |

### Stdlib: `std.process.Child`

| Pattern | File:line | Action |
|---|---|---|
| `var child = std.process.Child.init(argv, allocator);` | `labelle-gui/src/compiler.zig:92,128`, `src/preview.zig:183`; `labelle-cli/src/cli/{runner,docker,serve,update,assembler}.zig`, `src/cli/android/package.zig:227` | Init signature stable. |
| `var child: std.process.Child = .init(…);` | `labelle-cli/src/cli/{runner,docker,serve,android/package,android/deploy,assembler,update}.zig` (decl-literal form) | Stable. |
| `child.spawn() / child.wait()` | as above | Stable. |
| `child.stdout.?.readToEndAlloc(alloc, max)` | `labelle-gui/src/compiler.zig:102-103,167-168` | The reader API change — see Io rewrite row above. `child.stdout` becomes a `?std.fs.File` whose reader needs the new shape. |
| `std.process.Child.run(.{ … })` (the high-level helper) | `labelle-cli/src/cli/{util,runner,ios}.zig` | Helper is stable on 0.16; returns the same `RunResult`. |

### Syntax / builtins

| Change | Used here? |
|---|---|
| `callconv(.c)` (lower-case `.c`) — already the 0.15.2 form, the upper-case `.C` alias was removed in 0.16 | `labelle-gui/src/main.zig:26` already uses `.c`. `labelle-cli/src/cli/runner.zig:6` uses `callconv(.c)`. No action. |
| `@Enum(tag_type, .exhaustive, &names, &values)` reflection builtin | **Only used by upstream `zopengl` 0.16+**; not used in toolkit source directly. Forces the zopengl pin bump (see Dependency Pin Map). |
| `@enumFromInt`, `@intFromEnum`, `@bitCast`, `@intCast`, `@bitOffsetOf`, `@errorName`, `@floatCast`, `@floatFromInt` | All used across `labelle-gui/src/*`. All stable in 0.16. |
| `std.atomic.Value(T).init(…)`, `.load(.acquire)`, `.store(v, .release)`, `.swap(v, .acquire)` | `labelle-gui/src/main.zig:23-28,120-121`. Stable in 0.16. |

### Other 0.16 caveats not directly observed here

- `usingnamespace` removal — toolkit search found no `usingnamespace` in our source. Confirmed clean.
- Top-level `pub const std_options: std.Options = …` shape — used at `labelle-gui/src/main.zig:14`. Stable on 0.16.
- `GeneralPurposeAllocator` rename / behaviour — `labelle-gui/src/{main,gui_tests}.zig` use the 0.15 syntax `std.heap.GeneralPurposeAllocator(.{}){}`; 0.16 keeps this. The newer `std.heap.DebugAllocator` exists alongside.

## Dependency pin map

For every external pin in the cluster, the table below records the current commit, whether upstream has a 0.16-ready commit, and the recommended target.

| Dep | Used by | Current pin (date) | 0.16-ready upstream | Notes / risk |
|---|---|---|---|---|
| `zgui` | labelle-gui | `b6a4dff52d` (2026-03-05) — pre-0.16 | **`9c0b41af12` (2026-05-12)** "Upgrade to Zig 0.16.0", or `bfbebed372` (2026-05-12, HEAD as of survey) which is "Fixes DPI scaling for GLFW windows (#102)" on top of the 0.16 commit | Both `with_node_editor` and `with_te` options remain on the 0.16 branch — verified in `build.zig` of `9c0b41af12`. Backend enum still includes `glfw_opengl3`. Should be drop-in replacement at the build-system level. DPI fix in HEAD is a bonus for our manifest path. |
| `zglfw` | labelle-gui | `0dd29d8073` (2026-02-28) — pre-0.16 | **`6d3bc49ed6` (2026-04-22)** "zig v0.16 (#51)", or `51003c105d` (CI build on 0.14.1 + 0.15.2 + 0.16.0) which is the current HEAD | `createWindow` is still 5-arg `(width, height, title, monitor, share)` on both pre- and post-0.16 — **the CLAUDE.md "5-arg in pre-0.16, different in 0.16" note is incorrect / stale**. Verified by inspecting `src/zglfw.zig` at both revisions. No call-site change needed in `main.zig:47`. |
| `zopengl` | labelle-gui | `db9d615c74` (2026-02-12) — pre-0.16; **no `@Enum`** | **`29908b1ba2` (2026-05-02)** "Update to Zig 0.16.0 (#34)" — adds `@Enum` reflection helper, requires Zig 0.16 | Confirmed via diff: pre-0.16 wrapper has 0 occurrences of `@Enum`; 0.16 wrapper introduces it. **Hard gate on the Zig bump** — bumping zopengl without bumping Zig will fail to compile. |
| `zstbi` | labelle-gui | `664305dd52` (2025-12-09) — pre-0.16 | **`3813f5f113` (2026-05-11)** "updated to zig 0.16. (#14)" | Drop-in. Only used in `main.zig:68-69` (init/deinit) and `atlas.zig` (image decode). |
| `nfd` (`fabioarnold/nfd-zig`) | labelle-gui | `master`-branch tarball (no commit pin) → resolves to whatever master happens to be when fetched (currently `031b6b08c2`, 2026-04-08) | **Unverified for 0.16**; recent commits are build-fix vintage with no 0.16 callout. | **Open question**. Mitigation: pin the URL to a specific commit (`refs/heads/master` is a soft pin that will drift). Test against 0.16. **Plan B if it breaks**: fork to `labelle-toolkit/labelle-nfd`, apply minimal 0.16 patches (likely just stdlib `Io` shim + `ArrayList` rename), and PR upstream in parallel. The library is ~500 LoC of Zig wrapping a vendored cross-platform native dialog — the migration scope is small and contained. |
| `cimgui` (`floooh/dcimgui`) | labelle-imgui | `4557d7526fdd` (commit form, sub-resource via `git+`) | **Open question** — needs `gh api repos/floooh/dcimgui` survey; not done in this RFC. | The `git+` URL form is already painful (see `flying-platform-labelle/project.labelle` line 27 comment: "broken cached imgui v0.1.2 release whose regenerated build.zig.zon has a git+ URL that zig fetch cannot resolve"). Bumping is a chance to switch to a tarball URL. **Plan B if upstream doesn't support 0.16**: fork to `labelle-toolkit/labelle-cimgui` with the minimum-version bump applied. The Zig surface is thin (`build.zig` + a small generator); the bulk is generated C bindings that don't depend on the host Zig version. |
| `zspec` | labelle-gui (tests), labelle-cli (tests), labelle-engine.jsonc | `v0.8.0` (`e19d2893cb`, 2026-05-05) — on 0.15.2 | **Not available** — no 0.16 commit yet | **Blocking**. Options: (a) PR upstream and wait; (b) fork to `apotema/zspec` `0.16` branch (the maintainer is also the user, `apotema/zspec`, so this is friction-free); (c) self-host a minimal fork. The diff for zspec is likely small (it's a tiny test runner). |
| `labelle_assembler` | labelle-cli | `1c24f303586c…` v0.8.0 | **Open question** — repo not present locally; needs upstream survey | The CLI depends on the assembler module; gui delegates to CLI via launcher. The chain has to migrate together for end-to-end builds. |
| `labelle-core` v1.4.0 | labelle-fsm (URL-fetch) | tarball of `v1.4.0` | **Open question** — repo not present locally | Path-deps in engine, gfx, scene (`../labelle-core`) reach a directory that does not exist in this checkout. Validation gap. |
| `cimgui` upstream-state | labelle-imgui | see above | **Open question** | Investigate as part of the labelle-imgui bump. |

## Per-repo migration checklist

Each repo gets bumped to Zig 0.16.0 in CI, its dep pins bumped, and its source patched for the stdlib changes. The "stdlib touchpoints" column is the per-repo work item count.

### `labelle-gui` (the hot path)

Touchpoints: 6 dep bumps, 14 `readToEndAlloc` sites, ~15 `ArrayList = .{}` sites, 0 `std.json.Stringify` sites, 0 `usingnamespace` sites. Touches `~/src/{compiler,prefs,tests,modules/flow}.zig` for IO and `~/src/{app,scene_io,gizmo_io,project,flows/*}.zig` for ArrayList style.

- [ ] Bump CI `mlugg/setup-zig@v2.version` to `0.16.0` in **both** `.github/workflows/ci.yml` and `.github/workflows/release.yml` (the latter is currently at `0.15.1` — drift bug to fix in the same PR).
- [ ] Add `minimum_zig_version = "0.16.0"` to `build.zig.zon`.
- [ ] Bump `build.zig.zon` dep pins:
  - `zgui` → `9c0b41af12` (or `bfbebed372` for the DPI fix; pick whichever still tests green). Recompute `hash`.
  - `zglfw` → `6d3bc49ed6` (or `51003c105d`). Recompute `hash`.
  - `zopengl` → `29908b1ba2`. Recompute `hash`.
  - `zstbi` → `3813f5f113`. Recompute `hash`.
  - `nfd` → pin a specific commit (replace `refs/heads/master` with `031b6b08c2.tar.gz` or the verified-good commit). Recompute `hash`.
  - `zspec` → after we have a 0.16-ready fork/branch.
- [ ] Verify `main.zig:47` `createWindow(1280, 720, "Labelle", null, null)` continues to compile against the 0.16 zglfw — signature is unchanged (5-arg in both). No call-site edit expected.
- [ ] Replace `std.fs.File.readToEndAlloc(allocator, max)` everywhere with the 0.16 idiom. Suggested helper: introduce `src/util/io.zig:readAllOwned(allocator, file, max)` and use it from `compiler.zig`, `prefs.zig`, `modules/flow.zig`, and the test files. Single function = single audit point.
- [ ] Run the `std.ArrayList(T) = .{}` → `.empty` (or leave `.{}` — both compile, but `.empty` is the new convention) and `std.ArrayListUnmanaged(T) = .{}` → `std.ArrayList(T) = .empty` sweep. Verify every `.append`/`.deinit`/`.appendSlice` passes an allocator.
- [ ] Re-verify `zgui` API surface — `with_node_editor`, `with_te`, `glfw_opengl3` backend, `FontConfig.init`, `zgui.te.getTestEngine`, font/glyph helpers — against the 0.16 zgui release. The shape of `Backend` enum is preserved (verified). If any function rename slipped in, fix the call sites in `main.zig` and `gui_tests.zig`.
- [ ] Re-verify `zopengl` — `loadCoreProfile`, `bindings.viewport / clearColor / clear / COLOR_BUFFER_BIT` (in `main.zig:141-143`), and the `@enumFromInt(@as(u64, tex_id))` in `modules/viewport.zig:345`. The `@Enum`-using wrapper exposes the same `bindings.*` C shape; risk is in the wrapper-API side if `atlas.zig` or `viewport.zig` ever migrates to it.
- [ ] **Remove the stale `zglfw createWindow` signature note from `CLAUDE.md`** ("Dep pinning notes" → second bullet). Confirmed against upstream that the signature is 5-arg in both pre- and post-0.16. The note is misleading; delete or rewrite as a generic "verify call sites" reminder.
- [ ] `zig build && zig build test && zig build gui-test && zig build smoke` all green.

### `labelle-cli`

Touchpoints: 1 `readToEndAlloc` (`src/cli/bake.zig:86`, on the PNG file), ~10 `std.ArrayList = .{}` sites, no `std.json.Stringify`.

- [ ] Bump CI `mlugg/setup-zig@v2.version` to `0.16.0` in `.github/workflows/{ci,release}.yml`.
- [ ] Set `build.zig.zon:minimum_zig_version = "0.16.0"`.
- [ ] Bump `labelle_assembler` dep pin to the 0.16-ready assembler commit (gated on upstream).
- [ ] Bump `zspec` dep pin to a 0.16-ready release (gated).
- [ ] Replace `png_file.readToEndAlloc(allocator, png_stat.size)` in `bake.zig` with the 0.16 idiom.
- [ ] Sweep `ArrayList = .{}` (cli.zig:701, 774, 1014, 1023; android_sdk:86; assembler:351; android/package:304; android/build:47,89,130; android/deploy:88; test:144,157; init:65; lockfile:6; upgrade:94,114; runner:162) — every site already passes an allocator on `.append`/`.deinit`, but verify.
- [ ] Bump CLI version (`1.37.0` → `1.38.0`). Cut a release that pins the 0.16 assembler.
- [ ] `zig build && zig build test`.

### `labelle-engine`

Touchpoints: 3 `readToEndAlloc` sites (`atlas.zig:543`, `prefab_cache.zig:68`, `scene_loader.zig:233`), 1 `std.json.Stringify.valueAlloc` site (`preview_mode.zig:433`), ~12 `ArrayList = .{}` sites, large test surface (33 test files).

- [ ] Bump CI `mlugg/setup-zig@v2.version` to `0.16.0` in `.github/workflows/{ci,mobile-build}.yml`.
- [ ] `build.zig.zon:minimum_zig_version = "0.16.0"`.
- [ ] Bump path-dep `labelle_core` to the migrated version (gated — requires labelle-core 0.16 work). Sub-pkgs `scene/build.zig.zon`, `jsonc/build.zig.zon` follow.
- [ ] Replace `std.json.Stringify.valueAlloc` with `std.json.stringifyAlloc` (or whatever 0.16 calls it — confirm during implementation).
- [ ] Replace 3 `readToEndAlloc` sites with the 0.16 idiom. The `atlas.zig:543` one is a 10 MiB image load and benefits from streaming — consider deferring that to a follow-up.
- [ ] Sweep `ArrayList`s. `src/game.zig` has the densest usage (5 sites including the comptime-conditional `EventBuffer`).
- [ ] Re-verify the `single_threaded = true` test (`build.zig:108`) still compiles — this is the `#461` regression guard and `std.Thread` may have surface-level changes in 0.16.
- [ ] `zig build && zig build test` for the engine, the `scene` and `jsonc` sub-pkgs, **and** the asset-pipeline single-threaded test.

### `labelle-gfx`

Touchpoints: lots of `std.ArrayListUnmanaged(T) = .empty` already (good — matches 0.16 convention). No `readToEndAlloc`. No `std.json.Stringify`.

- [ ] Add a top-level `.github/workflows/ci.yml` (only `coverage.yml` exists today). Bump to Zig 0.16.0 there and in coverage.yml.
- [ ] `build.zig.zon:minimum_zig_version = "0.16.0"`.
- [ ] Bump path-dep `labelle_core` (gated). Sub-pkgs: `spatial_grid/`, `tilemap/`, `camera/` — each has its own `build.zig.zon` to update.
- [ ] Rename `std.ArrayListUnmanaged` → `std.ArrayList` everywhere (it's the same type in 0.16; this is hygiene, not functional).
- [ ] `zig build && zig build test`.

### `labelle-fsm`

Touchpoints: minimal. `src/{controller,root}.zig` + tests. No `readToEndAlloc`, no `ArrayList`.

- [ ] Bump `build.zig.zon:minimum_zig_version = "0.16.0"`.
- [ ] Bump the URL-pin for `labelle-core` from `v1.4.0` to a 0.16-ready tag (gated). The CLAUDE.md note in labelle-fsm explicitly anchors on v1.4.0 for `SavePolicy` shape — coordinate with labelle-core maintainers.
- [ ] Add CI workflow (currently none) and pin Zig 0.16.0.
- [ ] `zig build test`.

### `labelle-imgui`

Touchpoints: minimal Zig source (`src/adapter.zig`, `bridges/sokol/src/bridge.zig`). Mostly a wrapper around cimgui.

- [ ] `build.zig.zon:minimum_zig_version = "0.16.0"`.
- [ ] Verify cimgui (`floooh/dcimgui`) builds under Zig 0.16. If the current pin `4557d7526fdd` doesn't, find the upstream 0.16 commit. Replace the `git+https://…#sha` URL with a tarball URL where possible (cf. the `flying-platform-labelle/project.labelle:26-29` comment about cached-release breakage).
- [ ] Add CI workflow + pin Zig 0.16.0.
- [ ] `zig build`.

### `flying-platform-labelle`

The reference game — exercised via the `labelle` CLI launcher, not direct `zig build`.

- [ ] Bump CI `mlugg/setup-zig@v2.version` to `0.16.0` in `.github/workflows/{ci,deploy-pages}.yml`.
- [ ] Bump every plugin sub-project (`libs/{pathfinder,scheduler,caretaker,job_machine,debug,imgui,fsm,needs_machine,command_buffer,behavior_tree,worker_controller}/build.zig.zon`) `minimum_zig_version` to `0.16.0`. Verify each `libs/*/src/*.zig` for ArrayList-style work — `libs/pathfinder/src/{engine,graph,context,floyd_warshall}.zig` and `scripts/debug/98_snapshot_writer.zig` already use the unmanaged shape.
- [ ] Bump `project.labelle` pins (`core_version`, `engine_version`, `gfx_version`, `labelle_version`, `assembler_version`) once the upstream releases land.
- [ ] `labelle build && labelle run --timeout=30s` on macOS and Linux. The full smoke is gated on CLI 1.38.0+ pinning an assembler 0.16+.

### `labelle.games`

No Zig content. No action.

### Repos not present locally (for completeness)

- `labelle-core` — needs its own RFC pass. Every other repo path-deps it or URL-fetches it. **First on the rollout DAG.**
- `labelle-assembler` — needs its own RFC pass. Gated on labelle-core 0.16; gates the CLI release.

## Rollout order

Dependency DAG (consumers above, deps below):

```
flying-platform-labelle  ──depends on──►  labelle CLI launcher  (project.labelle pins)
                          \
                           └─►  labelle-engine ──►  labelle-core
                           │    labelle-gfx    ──►  labelle-core
                           │    labelle-fsm    ──►  labelle-core (v1.4 pinned)
                           │    labelle-imgui  ──►  cimgui (external)
                           │
labelle-cli  ────►  labelle-assembler  ────►  labelle-engine
                                       ────►  labelle-gfx
                                       ────►  labelle-core
                                       ────►  labelle-fsm  (overrideImport at game-build time)

labelle-gui  ────►  zgui, zglfw, zopengl, zstbi, nfd, zspec  (external)
             ────►  labelle CLI (via subprocess; no source-level dep)
```

Suggested merge order (each step assumes the previous is green):

1. **`labelle-core` → 0.16** (out of scope here — survey + RFC needed).
2. **`zspec` → 0.16** — fork or PR upstream. Without this, gui + cli + engine.jsonc tests don't build.
3. **`labelle-fsm` → 0.16** — small library, easy first-mover validation of zspec + core.
4. **`labelle-gfx` → 0.16** — mostly mechanical (ArrayListUnmanaged rename), depends on core only.
5. **`labelle-engine` → 0.16** — biggest stdlib surface (json.Stringify, readToEndAlloc, single-threaded asset path).
6. **`labelle-assembler` → 0.16** (out of scope here).
7. **`labelle-cli` → 0.16, release 1.38.0** — pins the new assembler.
8. **`labelle-imgui` → 0.16** (parallel with 5–7, no dep on the others except via game builds).
9. **`labelle-gui` → 0.16** — the loud dep bumps (zgui/zglfw/zopengl/zstbi/nfd) plus stdlib sweep. This is the PR currently in-flight that motivated the RFC.
10. **`flying-platform-labelle` → 0.16** — bump `project.labelle` and `libs/*` pins. Validate `labelle build && labelle run` end-to-end on macOS + Linux.

Steps 3–5 (and 8) can run in parallel once core + zspec land. Step 9 (gui) needs only its own dep stack; step 10 needs everything.

## Validation plan

Per-repo, after each bump:

| Repo | Commands | Notes |
|---|---|---|
| labelle-core | `zig build && zig build test` | Out of scope here. |
| zspec (fork) | `zig build && zig build test` against 0.16 | The runner-mode `.simple` referenced by `labelle-gui/build.zig:98` must continue to load. |
| labelle-fsm | `zig build test` (lib + controller_tests) | Both `test_step` deps must pass. |
| labelle-gfx | `zig build test` for root + each sub-pkg | `spatial_grid`, `tilemap`, `camera` each have their own tests. |
| labelle-engine | `zig build test` — all 33 test files + `assets_tests` + `assets_single_threaded` | The single-threaded test is the #461 regression guard; must compile clean. |
| labelle-cli | `zig build test` + a full e2e against `flying-platform-labelle` | Re-run `labelle generate / build / run --timeout=30s`. |
| labelle-imgui | `zig build` + bridge sub-projects compile | No tests today. |
| labelle-gui | `zig build && zig build test && zig build gui-test && zig build smoke` | `smoke` is end-to-end against the real `labelle` launcher — only meaningful after the CLI bump lands. Run `gui-test` under Xvfb in CI. |
| flying-platform-labelle | `labelle build && labelle run --timeout=30s` on macOS + Linux; `zig build` is forbidden (per CLAUDE.md) | The CI workflow drives `labelle` directly. |

## Open questions / unknowns

- **`zspec` 0.16 plan.** No 0.16 commit upstream. Will the maintainer (apotema) cut one, or do we fork? Blocks 3 repos.
- **`nfd-zig` 0.16 compatibility.** Last commits are build-fix vintage with no 0.16 callout. Test against 0.16 ASAP — if it breaks, the gui's Open/Save dialogs are blocked.
- **`labelle-core` and `labelle-assembler` are not present locally.** I cannot validate their 0.16-readiness from this checkout. The rollout assumes they each get their own migration RFC and merge sequentially. The cli depends on assembler, the engine/gfx/fsm depend on core; until those upgrade, downstream PRs can compile against 0.15-pinned versions but cannot end-to-end test.
- **`cimgui` (`floooh/dcimgui`) 0.16 readiness.** Not surveyed in this RFC. Needs `gh api` check. The `git+https://…#sha` URL form has already caused cache breakage (`flying-platform-labelle/project.labelle:26-29` comment) — bump is a chance to switch to tarball URLs.
- **`labelle-gui/.github/workflows/release.yml` is at Zig `0.15.1`, ci.yml at `0.15.2`.** Drift bug; release artifacts are built against a different Zig than CI tests. Fix in the same PR as the 0.16 bump (set both to 0.16.0).
- **Pre-0.16 `zglfw createWindow` signature concern in `labelle-gui/CLAUDE.md`.** The note says "5-arg in pre-0.16, different in 0.16". Confirmed false against upstream: the function is 5-arg `(width, height, title, monitor, share)` on **both** `0dd29d8073` (current pin) and `6d3bc49ed6` (0.16 commit). The CLAUDE.md note appears stale and should be removed/updated when the migration lands.
- **`zgui` HEAD vs the exact 0.16 commit.** `9c0b41af12` is the "Upgrade to Zig 0.16.0" commit; `bfbebed372` (HEAD) is the DPI fix that may matter for our `setContentScaleCallback` path. Recommend trying HEAD first; fall back to the upgrade commit if anything breaks.
- **`labelle-fsm` pins `labelle-core` to `v1.4.0` for `SavePolicy` test isolation.** When labelle-core migrates to 0.16, does the v1.4.0 line get a 0.16 backport, or does fsm float forward to a newer tag? Coordinate with labelle-core maintainers.
- **Smoke-test gating in the gui PR.** `zig build smoke` is meaningful only when the `labelle` CLI on PATH is itself 0.16-compatible. Until CLI 1.38.0 lands, gui PR validation has to rely on `zig build test` + `zig build gui-test`. Smoke runs once a release-candidate CLI is available.
- **`labelle-engine/build.zig.zon` path-deps `../labelle-core`** — without `labelle-core` checked out locally, even `zig build` against the current 0.15.2 tree fails. This is a pre-existing dev-environment gap, not a 0.16-specific problem, but the migration cannot be validated locally until labelle-core is cloned.
