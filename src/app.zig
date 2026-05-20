//! `App` holds the GUI's per-instance state and drives one frame of UI.
//!
//! `main.zig` and `gui_tests.zig` both construct an `App`: the former in a
//! visible GLFW window with a real event loop, the latter in a hidden one
//! driven by the ImGui Test Engine. Anything that should be reachable from
//! tests (project state, compiler state, panel toggles) lives here.

const std = @import("std");
const zglfw = @import("zglfw");
const zgui = @import("zgui");
const nfd = @import("nfd");

const project = @import("project.zig");
const tree_view = @import("tree_view.zig");
const compiler = @import("compiler.zig");
const preview = @import("preview.zig");
const config = @import("config.zig");
const module = @import("module.zig");
const compiler_output = @import("modules/compiler_output.zig");
const project_settings_mod = @import("modules/project_settings.zig");
const project_tree_mod = @import("modules/project_tree.zig");
const resources_mod = @import("modules/resources.zig");
const preview_mod = @import("modules/preview.zig");
const scene_mod = @import("modules/scene.zig");
const prefab_mod = @import("modules/prefab.zig");
const flow_mod = @import("modules/flow.zig");
const gizmo_mod = @import("modules/gizmo.zig");
const entity_inspector_mod = @import("modules/entity_inspector.zig");
const game_view_mod = @import("modules/game_view.zig");
const atlas_viewer_mod = @import("modules/atlas_viewer.zig");
const game_view = @import("game_view.zig");
const io_global = @import("io_global.zig");
const flow_runtime_mod = @import("modules/flow_runtime.zig");
const close_scene_dialog = @import("dialogs/close_scene.zig");
const atlas = @import("atlas.zig");
const gizmos = @import("gizmos.zig");
const prefab_index = @import("prefab_index.zig");
const new_scene_dialog = @import("dialogs/new_scene.zig");
const dpi_warning_dialog = @import("dialogs/dpi_warning.zig");
const preferences_dialog = @import("dialogs/preferences.zig");
const prefs_mod = @import("prefs.zig");

const STATUS_BUF_LEN = 256;
const SCENE_NAME_BUF_LEN = 128;

/// One entry in the main-content tab strip. Each variant wraps an
/// editor's per-tab state (loaded file, dirty flag, view state) and
/// the tab strip + close-confirmation modal dispatch through the
/// shared methods (`displayName`, `path`, `isDirty`, `save`, `render`,
/// `deinit`) below. Add a new editor by adding a variant and a case
/// to each method.
pub const OpenTab = union(enum) {
    scene: scene_mod.SceneState,
    prefab: prefab_mod.PrefabState,
    /// Visual-scripting "flow graph" editor — spike for issue #45.
    /// `save`/`isDirty` are no-ops until Phase 1 lands the
    /// `.flow.zon` schema.
    flow: flow_mod.FlowState,
    gizmo: gizmo_mod.GizmoState,
    /// Live game view (#128). Routing marker only — the consumer +
    /// GL texture state live on `App.game_view`. No per-tab struct
    /// because there's only one preview session at a time, and the
    /// tab body just dispatches into `modules/game_view.zig`'s
    /// existing renderer.
    game_view: void,

    pub fn deinit(self: *OpenTab, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scene => |*s| s.deinit(allocator),
            .prefab => |*p| p.deinit(allocator),
            .flow => |*f| f.deinit(allocator),
            .gizmo => |*g| g.deinit(allocator),
            .game_view => {},
        }
    }

    pub fn render(self: *OpenTab, app: *App) void {
        switch (self.*) {
            .scene => |*s| scene_mod.render(s, app),
            .prefab => |*p| prefab_mod.render(p, app),
            .flow => |*f| flow_mod.render(f, app),
            .gizmo => |*g| gizmo_mod.render(g, app),
            .game_view => game_view_mod.renderTab(app),
        }
    }

    pub fn save(self: *OpenTab, app: *App) void {
        switch (self.*) {
            .scene => |*s| scene_mod.saveScene(s, app),
            .prefab => |*p| prefab_mod.savePrefab(p, app),
            .flow => |*f| flow_mod.saveFlow(f, app),
            .gizmo => |*g| gizmo_mod.saveGizmo(g, app),
            .game_view => {},
        }
    }

    pub fn displayName(self: OpenTab) []const u8 {
        return switch (self) {
            .scene => |s| s.display_name,
            .prefab => |p| p.display_name,
            .flow => |f| f.display_name,
            .gizmo => |g| g.display_name,
            .game_view => "▶ Game View",
        };
    }

    pub fn path(self: OpenTab) []const u8 {
        return switch (self) {
            .scene => |s| s.path,
            .prefab => |p| p.path,
            .flow => |f| f.path,
            .gizmo => |g| g.path,
            .game_view => "<runtime>",
        };
    }

    pub fn isDirty(self: OpenTab) bool {
        return switch (self) {
            .scene => |s| s.is_dirty,
            .prefab => |p| p.is_dirty,
            .flow => |f| f.is_dirty,
            .gizmo => |g| g.is_dirty,
            .game_view => false,
        };
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,

    project_manager: project.ProjectManager,
    tree_view: tree_view.TreeView,
    compiler: compiler.Compiler,
    /// Preview-mode session (issue #61). Lifetime spans the App; `start`/
    /// `stop` drive transitions, `poll` is ticked every frame. The
    /// `preview` panel module reads its state for the status line.
    preview: preview.PreviewSession,

    status_message: [STATUS_BUF_LEN]u8 = [_]u8{0} ** STATUS_BUF_LEN,
    status_timer: f32 = 0,

    /// Toggled by the View menu, the Build menu, and the Compiler Output
    /// module. The module reads this via its `Module.is_open` pointer.
    show_compiler_output: bool = false,
    compiler_output_scroll_to_bottom: bool = false,
    /// Tail buffer for the Compiler Output panel's live preview view
    /// (#127). The panel pulls newly-arrived stderr bytes from
    /// `preview.PreviewSession.consumeStderr` each frame and appends
    /// them here, so the build phase's progress is visible live
    /// instead of only on `.crashed`. Capped to keep the buffer from
    /// growing without bound on a chatty subprocess; older bytes are
    /// discarded from the front when the cap is hit. Reset on every
    /// fresh `startPreview`.
    preview_tail: std.ArrayList(u8) = .empty,

    show_project_settings: bool = false,
    project_settings: project_settings_mod.ProjectSettings = .{},

    show_resources: bool = false,
    resources_editor: resources_mod.ResourcesEditor = .{},

    /// Toggled by the View menu and the Build menu's "Run preview"
    /// action. The Preview panel reads this via its `Module.is_open`
    /// pointer; clicking Run preview also force-opens it.
    show_preview: bool = false,
    /// Scene name (no extension) the user picked from the Run-button
    /// dropdown (#132). When non-null, passed as `--scene=<name>` to
    /// `labelle run`. `null` falls back to `project.labelle`'s
    /// `initial_scene` field — the pre-#132 behavior.
    ///
    /// Borrowed from the active project's arena (scene name strings
    /// returned by `Project.scenesAvailable`). Reset to null on project
    /// transition (`closeAllTabs` codepath in `renderFrame`) so a stale
    /// pointer from the old project's arena can't leak into a fresh
    /// `preview.start` call.
    preview_scene_override: ?[]const u8 = null,

    /// Game View panel state (#107). Owns the SHM consumer + GL
    /// texture for the live game frames. Toggleable from the View
    /// menu; until the editor-side preview transport is restored
    /// (separate follow-up), the consumer is attached either via
    /// `App.attachGameView` or the `LABELLE_GAME_VIEW_SHM` env var.
    show_game_view: bool = false,
    game_view: game_view.GameView = undefined,

    /// Atlas Viewer panel toggle (#148).
    show_atlas_viewer: bool = false,
    /// Atlas Viewer panel state — selected atlas/sprite, zoom, and any
    /// packed-and-opened atlases.
    atlas_viewer: atlas_viewer_mod.AtlasViewer = .{},

    /// Phase 3 (#84): Entity Inspector panel toggle.
    show_entity_inspector: bool = false,
    /// Entity Inspector state — fed by `PreviewSession`'s
    /// `on_component_changed` callback (wired in `init`).
    entity_inspector: entity_inspector_mod.EntityInspector = undefined,

    /// Phase 3 (#84): Flow Runtime panel toggle.
    show_flow_runtime: bool = false,
    /// Flow Runtime state — tracks subscribed-to flows and the
    /// rolling `node_entered` log. Fed by `PreviewSession`'s
    /// `on_node_entered` callback (wired in `init`).
    flow_runtime: flow_runtime_mod.FlowRuntime = .{},

    /// Open editor tabs — scenes and prefabs share this list as
    /// `OpenTab` variants. Populated when the user clicks an
    /// editable file in the project tree; closed via the × on a
    /// tab. `closeAllTabs` runs on project transitions.
    open_tabs: std.ArrayList(OpenTab) = .empty,
    /// Which tab is foregrounded. null when no tabs are open.
    /// Updated each frame from whichever tab ImGui reports active.
    active_tab_idx: ?usize = null,
    /// One-shot: when set, the next `renderSceneTabs` forces this tab
    /// to be active via ImGui's `set_selected` flag, then clears the
    /// field. `set_selected` is one-shot in ImGui — applying it every
    /// frame would re-force the same tab and prevent the user from
    /// switching by clicking other tabs.
    focus_tab_idx: ?usize = null,
    /// Set when the user clicks the × on a dirty tab. While non-null
    /// the close-confirmation dialog is shown and other tabs can't be
    /// closed.
    pending_close_idx: ?usize = null,
    /// Deferred "open prefab as a tab" path used by the scene editor's
    /// double-click + Edit-prefab affordance. The act of opening a
    /// prefab mutates `open_tabs`, which would invalidate the scene
    /// tab's `SceneState *s` pointer mid-render. Setting this field
    /// during render and processing it on the next frame keeps the
    /// list stable for the rest of the current frame.
    pending_open_prefab_path: ?[]u8 = null,
    /// Last seen `ProjectManager.generation`. Compared each frame so
    /// `closeAllTabs` runs the frame the active project changes.
    last_project_generation: ?u64 = null,

    /// Per-project atlas index (sprite name → frame + GL texture).
    /// Built lazily the first frame the active project's generation
    /// is observed; invalidated when the generation bumps. Inspector
    /// + viewport consult it to validate `sprite_name` and draw the
    /// real pixels for entities with a Sprite component.
    atlas_index: ?atlas.Index = null,
    /// Per-project gizmo overlay index. Built alongside `atlas_index`
    /// on project new/load; viewport queries it when `show_gizmos`
    /// is true to draw debug visualizations over matched entities.
    gizmo_index: ?gizmos.Index = null,
    /// Per-project prefab cache (name → parsed prefab). Built alongside
    /// `atlas_index` and `gizmo_index`; the scene viewport uses it to
    /// resolve `{ "prefab": "canteen" }` references into renderable
    /// sprites when the scene entity has no Sprite component of its
    /// own. Invalidated when the project generation bumps.
    prefab_index: ?prefab_index.Index = null,
    /// User toggle for the gizmo overlay; on by default so the
    /// overlay shows up immediately when a project with gizmos opens.
    show_gizmos: bool = true,

    show_project_tree: bool = true,
    /// Current width of the Project Tree sidebar (in screen px). The
    /// user can resize the sidebar by dragging its right edge; the new
    /// width is read back from ImGui each frame and stored here. Main
    /// content's left position + width derives from this value so the
    /// editor area follows the drag. Initialized from
    /// `config.ui.sidebar_width`.
    sidebar_width: f32 = config.ui.sidebar_width,

    show_new_scene_dialog: bool = false,
    new_scene_name: [SCENE_NAME_BUF_LEN:0]u8 = [_:0]u8{0} ** SCENE_NAME_BUF_LEN,
    show_dpi_warning: bool = false,

    show_preferences: bool = false,
    /// Live preferences edited by the Preferences dialog. Changes are
    /// persisted to disk on every slider/stepper edit; the ImGui font
    /// atlas isn't rebuilt mid-session so values take effect on the
    /// next launch (the dialog surfaces a "Restart to apply" notice
    /// when `prefs.font_scale != startup_font_scale`).
    prefs: prefs_mod.Preferences = .{},
    /// Snapshot of `prefs` at startup. Drives the "Restart to apply"
    /// hint: when `prefs` diverges from this we know the user changed
    /// something that won't take effect until next launch.
    startup_prefs: prefs_mod.Preferences = .{},

    /// Fixed-size storage for registered modules. Grow the array literal
    /// when adding modules; Zig will tell you if it overflows.
    modules: [9]module.Module = undefined,
    registry: module.Registry = .{ .modules = &.{} },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window, user_prefs: prefs_mod.Preferences) !*Self {
        const app = try allocator.create(Self);
        errdefer allocator.destroy(app);

        app.* = .{
            .allocator = allocator,
            .window = window,
            .project_manager = project.ProjectManager.init(allocator),
            .tree_view = tree_view.TreeView.init(allocator),
            .compiler = compiler.Compiler.init(allocator),
            .preview = preview.PreviewSession.init(allocator),
            .game_view = game_view.GameView.init(allocator),
            .prefs = user_prefs,
            .startup_prefs = user_prefs,
        };

        // The inspector keeps a `*PreviewSession` so it can call
        // `watchEntity`/`unwatchEntity` from its own callbacks without
        // routing through `App`. Initialize after `preview` so the
        // pointer is stable for the lifetime of the App.
        app.entity_inspector = entity_inspector_mod.EntityInspector.init(allocator, &app.preview);

        // Wire the preview session's `frame_offer` listener — the
        // editor-side end of #112's transport restore + #107's Game
        // View panel meet here. When the engine emits `frame_offer`
        // the transport calls back into App, which attaches the
        // Game View consumer to the advertised SHM region. Tests
        // can drive this end-to-end via `bindListener` +
        // `LABELLE_GAME_VIEW_SHM`, the production path uses
        // `start(project)` + `labelle run` spawn.
        app.preview.on_frame_offer = .{
            .ctx = app,
            .func = struct {
                fn cb(ctx: *anyopaque, shm_name: [:0]const u8, width: u32, height: u32, format: []const u8) void {
                    _ = width;
                    _ = height;
                    const a: *App = @ptrCast(@alignCast(ctx));
                    a.attachGameView(shm_name, format) catch |err| {
                        std.log.warn(
                            "preview: attachGameView('{s}', '{s}') failed: {s}",
                            .{ shm_name, format, @errorName(err) },
                        );
                    };
                }
            }.cb,
        };

        // Wire the preview session's binary-frame listeners. Both are
        // single-consumer in Phase 3; future panels that need the same
        // stream will gain a multi-listener path.
        app.preview.on_component_changed = .{
            .ctx = app,
            .func = struct {
                fn cb(ctx: *anyopaque, entity_id: u64, name: []const u8, bytes: []const u8) void {
                    const a: *App = @ptrCast(@alignCast(ctx));
                    a.entity_inspector.onComponentChanged(entity_id, name, bytes);
                }
            }.cb,
        };
        app.preview.on_node_entered = .{
            .ctx = app,
            .func = struct {
                fn cb(ctx: *anyopaque, flow_name: []const u8, node_id: u32) void {
                    const a: *App = @ptrCast(@alignCast(ctx));
                    a.flow_runtime.onNodeEntered(flow_name, node_id);
                    // Pulse the matching flow editor tab if it's open
                    // — display name matches the `.flow.zon` stem the
                    // engine emits. Tabs that aren't flows or whose
                    // names don't match are skipped silently.
                    for (a.open_tabs.items) |*tab| {
                        switch (tab.*) {
                            .flow => |*f| {
                                if (std.mem.eql(u8, f.display_name, flow_name)) {
                                    flow_mod.pulseNode(f, node_id);
                                }
                            },
                            else => {},
                        }
                    }
                }
            }.cb,
        };

        app.modules[0] = project_tree_mod.makeModule(app);
        app.modules[1] = compiler_output.makeModule(app);
        app.modules[2] = project_settings_mod.makeModule(app);
        app.modules[3] = resources_mod.makeModule(app);
        app.modules[4] = preview_mod.makeModule(app);
        app.modules[5] = entity_inspector_mod.makeModule(app);
        app.modules[6] = flow_runtime_mod.makeModule(app);
        app.modules[7] = game_view_mod.makeModule(app);
        app.modules[8] = atlas_viewer_mod.makeModule(app);
        app.registry = .{ .modules = &app.modules };

        // Honor LABELLE_GAME_VIEW_SHM as a manual attach path until
        // the preview-transport restore wires this up automatically.
        // Empty / unset → no attach. Lookup errors (missing region,
        // bad magic) are logged but don't fail App.init — the user
        // can still drive the editor without preview. GameView.attach
        // dupes the name into its own buffer.
        if (io_global.environ().getAlloc(allocator, "LABELLE_GAME_VIEW_SHM") catch null) |raw| {
            defer allocator.free(raw);
            if (raw.len > 0) {
                // Env-var hook is shm-only; the iosurface dispatch
                // arrives through the engine's `frame_offer` JSON.
                app.game_view.attach(raw, "bgra8") catch |err| {
                    std.log.warn("game_view: attach('{s}') failed: {s}", .{ raw, @errorName(err) });
                };
                if (app.game_view.isAttached()) app.show_game_view = true;
            }
        }

        return app;
    }

    pub fn deinit(self: *Self) void {
        self.closeAllTabs();
        self.open_tabs.deinit(self.allocator);
        self.preview_tail.deinit(self.allocator);
        if (self.atlas_index) |*idx| idx.deinit();
        if (self.gizmo_index) |*idx| idx.deinit();
        if (self.prefab_index) |*idx| idx.deinit();
        if (self.pending_open_prefab_path) |p| self.allocator.free(p);
        // Phase 3 state. Entity Inspector frees its component table;
        // Flow Runtime frees its subscribed-flow name copies.
        self.entity_inspector.deinit();
        self.flow_runtime.deinit(self.allocator);
        self.project_manager.deinit();
        self.tree_view.deinit();
        self.compiler.deinit();
        self.preview.deinit();
        self.game_view.deinit();
        self.allocator.destroy(self);
    }

    /// Open the SHM region the engine advertised in `frame_offer`
    /// (#107). Convenience wrapper that surfaces the panel
    /// automatically on a successful attach.
    ///
    /// `format` mirrors the engine's `frame_offer.format` field —
    /// `"bgra8"` (the default for legacy callers) routes to the SHM
    /// CPU upload path, `"iosurface_bgra8"` routes to the macOS
    /// zero-copy path. Anything else falls back to SHM.
    pub fn attachGameView(self: *Self, shm_name: []const u8, format: []const u8) !void {
        try self.game_view.attach(shm_name, format);
        // #145: the docked tab is the default auto-open surface after
        // a preview attach. The floating "Game View" panel registered
        // via the Module Registry remains available as a manual
        // opt-in via the View menu (users who want a docked-elsewhere
        // layout). Both surfaces share `renderViewportContent` so
        // whichever is toggled on stays in lockstep with the live
        // attachment. We intentionally do NOT flip `show_game_view`
        // here — doing so opened both surfaces simultaneously and
        // rendered the same live frame twice (#145).
        // #128: open the Game View as a tab in the main content area
        // so users see the live frame inline with the editor tabs
        // they were working in. Logged + swallowed because an OOM
        // here shouldn't fail the attach — the floating panel still
        // works as a fallback if the user opens it from the menu.
        self.openGameViewTab() catch |err| {
            std.log.warn("attachGameView: openGameViewTab failed: {s}", .{@errorName(err)});
        };
        // Reply with `frame_accept` so the engine flips its
        // `frame_state` to `.accepted` and starts publishing —
        // without this, `signalSlotReady`/`publishFrame*` bounce
        // with `StreamNotActive` and the Game View stays at
        // "waiting for first frame" forever.
        self.preview.sendFrameAccept();
    }

    /// Push a `.game_view` tab onto `open_tabs` (or focus an existing
    /// one) and queue a one-shot focus request so the next frame
    /// brings it forward. Idempotent — multiple `frame_offer`s in a
    /// session refocus instead of duplicating tabs. #128.
    fn openGameViewTab(self: *Self) !void {
        for (self.open_tabs.items, 0..) |t, i| {
            switch (t) {
                .game_view => {
                    self.focus_tab_idx = i;
                    return;
                },
                else => {},
            }
        }
        try self.open_tabs.append(self.allocator, .{ .game_view = {} });
        const new_idx = self.open_tabs.items.len - 1;
        self.active_tab_idx = new_idx;
        self.focus_tab_idx = new_idx;
    }

    /// Rebuild the atlas index from the active project's
    /// `resources` block. Called whenever the project generation
    /// changes. Closing the project invalidates the index without
    /// rebuilding.
    fn rebuildAtlasIndex(self: *Self) void {
        if (self.atlas_index) |*idx| {
            idx.deinit();
            self.atlas_index = null;
        }
        const proj = self.project_manager.current_project orelse return;
        const dir = proj.dir orelse return;

        // Map ProjectConfig.resources → atlas.Resource (decoupling
        // the atlas module from project.zig). Allocated on the
        // stack via ArrayList because the count is small.
        var resources: std.ArrayList(atlas.Resource) = .empty;
        defer resources.deinit(self.allocator);
        for (proj.config.resources) |r| {
            resources.append(self.allocator, .{
                .name = r.name,
                .json = r.json,
                .texture = r.texture,
            }) catch return;
        }
        self.atlas_index = atlas.Index.build(
            self.allocator,
            dir,
            resources.items,
            self.project_manager.generation,
        );
    }

    /// Rebuild the gizmo overlay index by walking
    /// `<project_dir>/gizmos/`. Same generation-keyed invalidation
    /// rule the atlas index uses.
    pub fn rebuildGizmoIndex(self: *Self) void {
        if (self.gizmo_index) |*idx| {
            idx.deinit();
            self.gizmo_index = null;
        }
        const proj = self.project_manager.current_project orelse return;
        const dir = proj.dir orelse return;
        self.gizmo_index = gizmos.Index.build(
            self.allocator,
            dir,
            self.project_manager.generation,
        );
    }

    /// Rebuild the prefab cache by walking `<project_dir>/prefabs/`
    /// recursively and parsing every `.jsonc`. Same generation-keyed
    /// invalidation rule the atlas + gizmo indexes use.
    pub fn rebuildPrefabIndex(self: *Self) void {
        if (self.prefab_index) |*idx| {
            idx.deinit();
            self.prefab_index = null;
        }
        const proj = self.project_manager.current_project orelse return;
        const dir = proj.dir orelse return;
        self.prefab_index = prefab_index.Index.build(
            self.allocator,
            dir,
            self.project_manager.generation,
        );
    }

    // ─── Scene tabs ─────────────────────────────────────────────────────

    /// Open a `.jsonc` scene file (under `<project>/scenes/`) as a
    /// tab in the main content area. Already-open scenes refocus
    /// instead of reloading; `project_tree.isScenePath` is the
    /// router's path discriminator.
    pub fn openScene(self: *Self, path: []const u8) !void {
        // De-dup by path: refocus an existing tab rather than reloading.
        // Other variants (`prefab`) compare paths the same way.
        for (self.open_tabs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.path(), path)) {
                self.focus_tab_idx = i;
                return;
            }
        }

        var state = try scene_mod.SceneState.open(self.allocator, path);
        errdefer state.deinit(self.allocator);
        // Seed inspector width from prefs so the user's preferred
        // split carries across sessions (#140). In-tab drags update
        // both this field and prefs.
        state.inspector_width = self.prefs.inspector_width;
        try self.open_tabs.append(self.allocator, .{ .scene = state });
        const new_idx = self.open_tabs.items.len - 1;
        self.active_tab_idx = new_idx;
        self.focus_tab_idx = new_idx;
    }

    pub fn openPrefab(self: *Self, path: []const u8) !void {
        for (self.open_tabs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.path(), path)) {
                self.focus_tab_idx = i;
                return;
            }
        }

        var state = try prefab_mod.PrefabState.open(self.allocator, path);
        errdefer state.deinit(self.allocator);
        state.inspector_width = self.prefs.inspector_width;
        try self.open_tabs.append(self.allocator, .{ .prefab = state });
        const new_idx = self.open_tabs.items.len - 1;
        self.active_tab_idx = new_idx;
        self.focus_tab_idx = new_idx;
    }

    /// Queue a `openPrefab` call to run at the start of the next
    /// frame. Used by the scene editor's double-click + Edit-prefab
    /// affordance, which fires mid-render — opening a tab right then
    /// would realloc `open_tabs` and invalidate the scene's
    /// `SceneState` pointer the caller is still using. Path is dup'd
    /// onto the heap; ownership transfers to App until the request
    /// is flushed in `flushPendingOpens`.
    pub fn requestOpenPrefab(self: *Self, path: []const u8) void {
        if (self.pending_open_prefab_path) |existing| {
            // A pending request from earlier in the same frame was
            // never flushed (would only happen if this is called
            // twice in one frame). Drop the older one.
            self.allocator.free(existing);
            self.pending_open_prefab_path = null;
        }
        self.pending_open_prefab_path = self.allocator.dupe(u8, path) catch return;
    }

    fn flushPendingOpens(self: *Self) void {
        if (self.pending_open_prefab_path) |path| {
            self.pending_open_prefab_path = null;
            defer self.allocator.free(path);
            self.openPrefab(path) catch |err| {
                std.log.err("Failed to open prefab {s}: {s}", .{ path, @errorName(err) });
                self.setStatus("Error opening prefab!");
            };
        }
    }

    /// Open a `.zig` file (under `<project>/scripts/flows/`) as a
    /// read-only Flow viewer tab. The file is parsed via
    /// `std.zig.Ast` and projected into a node graph by
    /// `src/flows/projector.zig`; the tab body draws the graph in
    /// the imgui-node-editor canvas. See `src/modules/flow.zig` and
    /// issues #48 + #49.
    pub fn openFlow(self: *Self, path: []const u8) !void {
        for (self.open_tabs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.path(), path)) {
                self.focus_tab_idx = i;
                return;
            }
        }

        var state = try flow_mod.FlowState.open(self.allocator, path);
        errdefer state.deinit(self.allocator);
        try self.open_tabs.append(self.allocator, .{ .flow = state });
        const new_idx = self.open_tabs.items.len - 1;
        self.active_tab_idx = new_idx;
        self.focus_tab_idx = new_idx;
    }

    /// Open a `.zon` gizmo file (under `<project>/gizmos/`) as a tab
    /// in the main content area. De-dups by path; mirrors `openScene`
    /// and `openPrefab`. `project_tree.isGizmoPath` is the router's
    /// path discriminator.
    pub fn openGizmo(self: *Self, path: []const u8) !void {
        for (self.open_tabs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.path(), path)) {
                self.focus_tab_idx = i;
                return;
            }
        }

        var state = try gizmo_mod.GizmoState.open(self.allocator, path);
        errdefer state.deinit(self.allocator);
        try self.open_tabs.append(self.allocator, .{ .gizmo = state });
        const new_idx = self.open_tabs.items.len - 1;
        self.active_tab_idx = new_idx;
        self.focus_tab_idx = new_idx;
    }

    /// Close the tab at `idx` unconditionally. Caller asks the user
    /// about unsaved changes via `requestCloseTab` first.
    pub fn closeTab(self: *Self, idx: usize) void {
        if (idx >= self.open_tabs.items.len) return;
        // #128: closing the Game View tab is the runtime-view "stop"
        // affordance — there's no dirty-doc dialog; tear down the
        // preview subprocess + consumer eagerly. Done before the
        // tab is removed so `.game_view`-specific cleanup still has
        // an attached consumer to work with.
        switch (self.open_tabs.items[idx]) {
            .game_view => {
                self.preview.stop();
                self.game_view.detach();
                self.show_game_view = false;
            },
            else => {},
        }
        var removed = self.open_tabs.orderedRemove(idx);
        removed.deinit(self.allocator);

        if (self.open_tabs.items.len == 0) {
            self.active_tab_idx = null;
        } else if (self.active_tab_idx) |a| {
            if (a == idx) {
                self.active_tab_idx = if (idx > 0) idx - 1 else 0;
            } else if (a > idx) {
                self.active_tab_idx = a - 1;
            }
        }
        if (self.pending_close_idx) |p| {
            if (p == idx) {
                self.pending_close_idx = null;
            } else if (p > idx) {
                self.pending_close_idx = p - 1;
            }
        }
    }

    /// Close the tab at `idx`, prompting first if the tab is dirty.
    pub fn requestCloseTab(self: *Self, idx: usize) void {
        if (idx >= self.open_tabs.items.len) return;
        if (self.open_tabs.items[idx].isDirty()) {
            self.pending_close_idx = idx;
        } else {
            self.closeTab(idx);
        }
    }

    pub fn closeAllTabs(self: *Self) void {
        for (self.open_tabs.items) |*t| t.deinit(self.allocator);
        self.open_tabs.clearRetainingCapacity();
        self.active_tab_idx = null;
        self.focus_tab_idx = null;
        self.pending_close_idx = null;
    }

    pub fn setStatus(self: *Self, message: []const u8) void {
        @memset(&self.status_message, 0);
        const n = @min(message.len, self.status_message.len - 1);
        @memcpy(self.status_message[0..n], message[0..n]);
        self.status_timer = config.ui.status_message_duration;
    }

    /// Sync a new inspector-splitter width back to `self.prefs` and
    /// persist. Called by the scene + prefab editors on drag-release
    /// so the splitter widget itself can stay prefs-free. The equality
    /// guard avoids churning the file when a click ends without an
    /// actual drag.
    pub fn saveInspectorWidth(self: *Self, width: f32) void {
        if (self.prefs.inspector_width == width) return;
        self.prefs.inspector_width = width;
        prefs_mod.save(self.allocator, self.prefs) catch |err| {
            std.log.warn("prefs: could not persist inspector_width: {s}", .{@errorName(err)});
        };
    }

    /// One UI frame. `dt_seconds` is the wall-clock time since the last
    /// frame, used to decrement transient timers (status messages, etc.)
    /// so they last a consistent duration regardless of frame rate.
    /// Caller is responsible for `backend.newFrame`/`backend.draw`
    /// around this; the test harness needs that boundary to inject events.
    pub fn renderFrame(self: *Self, dt_seconds: f32) void {
        if (self.status_timer > 0) self.status_timer -= dt_seconds;

        // Process deferred actions from the previous frame BEFORE
        // touching the project/tab structures. Mid-frame "open this
        // prefab" requests (scene editor double-click + Edit prefab
        // button) queue here so the act of mutating `open_tabs`
        // doesn't invalidate the SceneState pointer the requester is
        // still rendering against.
        self.flushPendingOpens();

        // Project transitions close all open scene tabs so the next
        // frame doesn't read into freed memory belonging to the old
        // project. Detected via ProjectManager.generation, which is
        // bumped on new/load/close. The atlas index is also keyed
        // to the project so we rebuild it here.
        const gen = self.project_manager.generation;
        if (self.last_project_generation) |prev| {
            if (prev != gen) {
                self.closeAllTabs();
                self.rebuildAtlasIndex();
                self.rebuildGizmoIndex();
                self.rebuildPrefabIndex();
                // The override borrowed a string from the previous
                // project's arena, which is freed on the transition.
                // Drop it so the next Run uses `initial_scene` until
                // the user picks again (#132).
                self.preview_scene_override = null;
            }
        } else {
            self.rebuildAtlasIndex();
            self.rebuildGizmoIndex();
            self.rebuildPrefabIndex();
        }
        self.last_project_generation = gen;

        self.renderMenuBar();
        self.pollCompiler();
        self.preview.poll();
        self.renderMainContent();
        self.registry.renderAllPanels(self);
        self.renderStatusBar();
        new_scene_dialog.render(self);
        close_scene_dialog.render(self);
        dpi_warning_dialog.render(self);
        preferences_dialog.render(self);
    }

    // ─── Menu bar ───────────────────────────────────────────────────────

    fn renderMenuBar(self: *Self) void {
        if (!zgui.beginMainMenuBar()) return;
        defer zgui.endMainMenuBar();

        self.renderFileMenu();
        self.renderBuildMenu();
        self.registry.renderViewMenu();
        self.renderHelpMenu();
    }

    fn renderFileMenu(self: *Self) void {
        if (!zgui.beginMenu("File", true)) return;
        defer zgui.endMenu();

        if (zgui.menuItem("New Project...", .{})) self.pickFolderAndCreateProject();
        if (zgui.menuItem("Open Project...", .{})) self.pickFolderAndOpenProject();
        zgui.separator();
        if (zgui.menuItem("New Scene...", .{ .enabled = self.project_manager.current_project != null })) {
            self.show_new_scene_dialog = true;
            @memset(&self.new_scene_name, 0);
        }
        zgui.separator();
        if (zgui.menuItem("Save", .{})) self.saveProject();
        if (zgui.menuItem("Save As...", .{})) self.saveProjectAs();
        zgui.separator();
        if (zgui.menuItem("Close Project", .{})) {
            self.project_manager.closeProject();
            self.setStatus("Project closed");
        }
        zgui.separator();
        if (zgui.menuItem("Preferences...", .{})) self.show_preferences = true;
        zgui.separator();
        if (zgui.menuItem("Exit", .{})) self.window.setShouldClose(true);
    }

    fn renderBuildMenu(self: *Self) void {
        if (!zgui.beginMenu("Build", self.project_manager.current_project != null)) return;
        defer zgui.endMenu();

        const can_build = self.compiler.isIdle();
        if (zgui.menuItem("Sync Project Files", .{ .enabled = can_build })) {
            if (self.compiler.syncProjectFiles(&self.project_manager)) {
                self.setStatus("Project files synced!");
                self.tree_view.refresh();
            } else |err| {
                std.log.err("Error syncing project files: {}", .{err});
                self.setStatus("Error syncing project files!");
            }
        }
        zgui.separator();
        if (zgui.menuItem("Build", .{ .enabled = can_build })) self.startBuildOrRun(.build);
        if (zgui.menuItem("Run", .{ .enabled = can_build })) self.startBuildOrRun(.run);
        zgui.separator();
        // Preview mode (#61). Disabled while an existing preview session
        // is alive — the session is single-instance (multi-session is
        // punted in the #59 umbrella).
        const preview_active = self.preview.isActive();
        if (zgui.menuItem("Run preview", .{ .enabled = can_build and !preview_active })) self.startPreview();
        if (zgui.menuItem("Stop preview", .{ .enabled = preview_active })) self.stopPreview();
    }

    fn renderHelpMenu(_: *Self) void {
        if (!zgui.beginMenu("Help", true)) return;
        defer zgui.endMenu();
        if (zgui.menuItem("About", .{})) {}
    }

    // ─── Menu actions ───────────────────────────────────────────────────

    fn pickFolderAndCreateProject(self: *Self) void {
        const maybe = nfd.openFolderDialog(null) catch {
            self.setStatus("Error opening folder dialog!");
            return;
        };
        const folder = maybe orelse return;
        defer nfd.freePath(folder);

        const name = std.fs.path.basename(folder);
        self.project_manager.newProject(name) catch |err| {
            std.log.err("Error creating project: {}", .{err});
            self.setStatus("Error creating project!");
            return;
        };
        self.project_manager.saveProject(folder) catch |err| {
            std.log.err("Error saving project: {}", .{err});
            self.setStatus("Error saving project!");
            return;
        };
        self.setStatus("New project created!");
        self.tree_view.refresh();
    }

    fn pickFolderAndOpenProject(self: *Self) void {
        const maybe = nfd.openFolderDialog(null) catch {
            self.setStatus("Error opening folder dialog!");
            return;
        };
        const folder = maybe orelse return;
        defer nfd.freePath(folder);

        self.project_manager.loadProject(folder) catch |err| {
            std.log.err("Error loading project: {}", .{err});
            self.setStatus("Error loading project!");
            return;
        };
        self.setStatus("Project loaded!");
        self.tree_view.refresh();
    }

    fn saveProject(self: *Self) void {
        const proj = self.project_manager.current_project orelse return;
        if (proj.dir) |dir| {
            self.project_manager.saveProject(dir) catch |err| {
                std.log.err("Save error: {}", .{err});
                self.setStatus("Error saving project!");
                return;
            };
            self.setStatus("Project saved!");
        } else {
            self.saveProjectAs();
        }
    }

    fn saveProjectAs(self: *Self) void {
        if (self.project_manager.current_project == null) return;
        const maybe = nfd.openFolderDialog(null) catch {
            self.setStatus("Error opening save dialog!");
            return;
        };
        const folder = maybe orelse return;
        defer nfd.freePath(folder);

        self.project_manager.saveProject(folder) catch |err| {
            std.log.err("Save error: {}", .{err});
            self.setStatus("Error saving project!");
            return;
        };
        self.setStatus("Project saved!");
    }

    const BuildKind = enum { build, run };
    fn startBuildOrRun(self: *Self, kind: BuildKind) void {
        const proj = self.project_manager.current_project orelse return;
        self.compiler.syncProjectFiles(&self.project_manager) catch |err| {
            std.log.err("Error syncing project files: {}", .{err});
            self.setStatus("Error syncing project files!");
            return;
        };
        const spawn_result = switch (kind) {
            .build => self.compiler.build(proj),
            .run => self.compiler.run(proj),
        };
        spawn_result catch |err| {
            std.log.err("Error starting {s}: {}", .{ @tagName(kind), err });
            self.setStatus("Error starting build!");
            return;
        };
        self.setStatus(if (kind == .run) "Running game..." else "Building...");
        self.show_compiler_output = true;
        self.compiler_output_scroll_to_bottom = true;
    }

    fn pollCompiler(self: *Self) void {
        if (self.compiler.pollBuild()) |result| {
            self.setStatus(if (result.success) "Build successful!" else "Build failed!");
            self.compiler_output_scroll_to_bottom = true;
        }
    }

    /// Spawn a preview-mode child process and surface the Preview
    /// panel. Mirrors `startBuildOrRun` shape: sync project files,
    /// hand off to the session, surface a status message. The session
    /// drives state from there via `poll()`.
    pub fn startPreview(self: *Self) void {
        const proj = self.project_manager.current_project orelse return;
        self.compiler.syncProjectFiles(&self.project_manager) catch |err| {
            std.log.err("Error syncing project files: {}", .{err});
            self.setStatus("Error syncing project files!");
            return;
        };
        // Reset the panel's live-tail buffer before the session
        // starts — old bytes from a previous Run shouldn't leak into
        // the new session's output.
        self.preview_tail.clearRetainingCapacity();
        self.preview.start(proj, self.preview_scene_override) catch |err| {
            std.log.err("Error starting preview: {}", .{err});
            self.setStatus("Error starting preview!");
            return;
        };
        self.setStatus("Preview starting...");
        self.show_preview = true;
        // Force-open the Compiler Output panel so the user sees the
        // subprocess's stderr live during the (potentially 30-60s)
        // cold `zig build` phase. Manual close via the panel × keeps
        // it closed for the rest of this Run; the next `startPreview`
        // call re-opens it on the next Run (#127).
        self.show_compiler_output = true;
        self.compiler_output_scroll_to_bottom = true;
    }

    /// Append `bytes` to the Compiler Output panel's live preview
    /// tail buffer (#127). Bounded by `preview_tail_cap` — when the
    /// buffer would exceed the cap, the oldest bytes are dropped from
    /// the front so the *recent* tail (where the build error or panic
    /// trace lives) is what the user sees. Called from the panel's
    /// per-frame `consumeStderr` drain; safe to call with an empty
    /// slice.
    pub fn appendPreviewTail(self: *Self, bytes: []const u8) void {
        if (bytes.len == 0) return;
        // Cap matches `preview.stderr_buf`'s cap (16 KiB) so the panel
        // never holds more than two windows' worth of stderr in flight.
        const preview_tail_cap: usize = 16 * 1024;
        if (bytes.len >= preview_tail_cap) {
            // Single record already exceeds the cap — keep only the
            // tail end.
            self.preview_tail.clearRetainingCapacity();
            const start = bytes.len - preview_tail_cap;
            self.preview_tail.appendSlice(self.allocator, bytes[start..]) catch return;
            return;
        }
        // Drop from the front if appending `bytes` would overflow.
        if (self.preview_tail.items.len + bytes.len > preview_tail_cap) {
            const need_to_drop = self.preview_tail.items.len + bytes.len - preview_tail_cap;
            const remaining = self.preview_tail.items.len - need_to_drop;
            std.mem.copyForwards(
                u8,
                self.preview_tail.items[0..remaining],
                self.preview_tail.items[need_to_drop..],
            );
            self.preview_tail.shrinkRetainingCapacity(remaining);
        }
        self.preview_tail.appendSlice(self.allocator, bytes) catch return;
    }

    pub fn stopPreview(self: *Self) void {
        self.preview.stop();
        self.setStatus("Preview stopped.");
    }

    // ─── Panels ─────────────────────────────────────────────────────────

    fn renderMainContent(self: *Self) void {
        const viewport = zgui.getMainViewport();
        const work_pos = viewport.getWorkPos();
        const work_size = viewport.getWorkSize();
        const sidebar_w = if (self.show_project_tree) self.sidebar_width else 0.0;
        zgui.setNextWindowPos(.{ .x = work_pos[0] + sidebar_w, .y = work_pos[1] });
        zgui.setNextWindowSize(.{ .w = work_size[0] - sidebar_w, .h = work_size[1] - config.ui.status_bar_height });

        if (!zgui.begin("##main", .{ .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .menu_bar = false,
        } })) {
            zgui.end();
            return;
        }
        defer zgui.end();

        // When at least one scene tab is open, the main area becomes
        // a TabBar; the welcome view is purely the empty-state. The
        // first frame after `openScene` selects the new tab via
        // `set_selected` so the user lands on what they just clicked.
        if (self.open_tabs.items.len > 0) {
            self.renderSceneTabs();
            return;
        }

        if (self.project_manager.current_project) |proj| {
            zgui.text("Project: {s}", .{proj.config.name});
            if (proj.is_dirty) {
                zgui.sameLine(.{});
                zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
            }
            zgui.separator();
            zgui.text("Click a scene in the tree to open it.", .{});
        } else {
            zgui.text("Welcome to Labelle!", .{});
            zgui.spacing();
            zgui.text("Create a new project or open an existing one.", .{});
            zgui.spacing();
            if (zgui.button("New Project...", .{ .w = 150 })) self.pickFolderAndCreateProject();
            if (zgui.button("Open Project...", .{ .w = 150 })) self.pickFolderAndOpenProject();
        }
    }

    /// Render the per-scene tab strip and the active tab's body. Tabs
    /// use `popen` on the tab item so the × close button fires through
    /// `requestCloseScene`, which routes a dirty tab to the
    /// confirmation dialog.
    fn renderSceneTabs(self: *Self) void {
        if (!zgui.beginTabBar("##scene_tabs", .{
            .reorderable = true,
            .auto_select_new_tabs = true,
            .tab_list_popup_button = true,
        })) return;
        defer zgui.endTabBar();

        // Consume the one-shot focus request *before* the loop so each
        // tab sees the same value and we don't re-apply it next frame.
        const focus = self.focus_tab_idx;
        self.focus_tab_idx = null;

        var to_close: ?usize = null;

        for (self.open_tabs.items, 0..) |*tab, i| {
            // Disambiguate tabs by full path so two scenes with the
            // same stem (across projects or fragments) get distinct
            // imgui IDs. `unsaved_document` puts ImGui's own marker
            // on dirty tabs. Buffer is sized for the longest plausible
            // absolute path (`std.fs.max_path_bytes`) plus slack for
            // the label prefix; smaller buffers silently dropped the
            // tab when pointed at deeply-nested project paths.
            var label_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}##{s}", .{ tab.displayName(), tab.path() }) catch continue;

            var open: bool = true;
            // `set_selected` is one-shot in ImGui — fire it only when
            // we explicitly want to bring a tab forward (just-opened
            // or re-focused via tree click on an already-open scene).
            // Applying it every frame creates a feedback loop that
            // prevents the user from switching tabs by clicking.
            const set_selected = focus != null and focus.? == i;
            const flags: zgui.TabItemFlags = .{ .set_selected = set_selected, .unsaved_document = tab.isDirty() };
            if (zgui.beginTabItem(label, .{ .p_open = &open, .flags = flags })) {
                self.active_tab_idx = i;
                tab.render(self);
                zgui.endTabItem();
            }
            if (!open and to_close == null) to_close = i;
        }

        if (to_close) |i| self.requestCloseTab(i);
    }

    fn renderStatusBar(self: *Self) void {
        const viewport = zgui.getMainViewport();
        const work_pos = viewport.getWorkPos();
        const work_size = viewport.getWorkSize();
        zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] + work_size[1] - config.ui.status_bar_height });
        zgui.setNextWindowSize(.{ .w = work_size[0], .h = config.ui.status_bar_height });

        if (zgui.begin("##statusbar", .{ .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_scrollbar = true,
        } })) {
            if (self.status_timer > 0) {
                zgui.text("{s}", .{std.mem.sliceTo(&self.status_message, 0)});
            } else if (self.project_manager.current_project) |proj| {
                if (proj.dir) |dir| {
                    zgui.text("{s}", .{dir});
                } else {
                    zgui.text("Unsaved project", .{});
                }
            } else {
                zgui.text("No project open", .{});
            }
        }
        zgui.end();
    }

};
