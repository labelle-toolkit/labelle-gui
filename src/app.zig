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
const config = @import("config.zig");
const module = @import("module.zig");
const compiler_output = @import("modules/compiler_output.zig");
const project_settings_mod = @import("modules/project_settings.zig");
const project_tree_mod = @import("modules/project_tree.zig");
const resources_mod = @import("modules/resources.zig");
const scene_mod = @import("modules/scene.zig");
const prefab_mod = @import("modules/prefab.zig");
const close_scene_dialog = @import("dialogs/close_scene.zig");
const atlas = @import("atlas.zig");
const new_scene_dialog = @import("dialogs/new_scene.zig");
const dpi_warning_dialog = @import("dialogs/dpi_warning.zig");

const STATUS_BUF_LEN = 256;
const SCENE_NAME_BUF_LEN = 128;

/// One entry in the main-content tab strip. Today only `scene`
/// exists; the `prefab` variant lands in a follow-up slice. The
/// union exists now so the tab strip, close-confirmation modal, and
/// `App.open_tabs` machinery don't need a second pass when prefab
/// support arrives — they already dispatch through the methods
/// below.
pub const OpenTab = union(enum) {
    scene: scene_mod.SceneState,
    prefab: prefab_mod.PrefabState,

    pub fn deinit(self: *OpenTab, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scene => |*s| s.deinit(allocator),
            .prefab => |*p| p.deinit(allocator),
        }
    }

    pub fn render(self: *OpenTab, app: *App) void {
        switch (self.*) {
            .scene => |*s| scene_mod.render(s, app),
            .prefab => |*p| prefab_mod.render(p, app),
        }
    }

    pub fn save(self: *OpenTab, app: *App) void {
        switch (self.*) {
            .scene => |*s| scene_mod.saveScene(s, app),
            .prefab => |*p| prefab_mod.savePrefab(p, app),
        }
    }

    pub fn displayName(self: OpenTab) []const u8 {
        return switch (self) {
            .scene => |s| s.display_name,
            .prefab => |p| p.display_name,
        };
    }

    pub fn path(self: OpenTab) []const u8 {
        return switch (self) {
            .scene => |s| s.path,
            .prefab => |p| p.path,
        };
    }

    pub fn isDirty(self: OpenTab) bool {
        return switch (self) {
            .scene => |s| s.is_dirty,
            .prefab => |p| p.is_dirty,
        };
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,

    project_manager: project.ProjectManager,
    tree_view: tree_view.TreeView,
    compiler: compiler.Compiler,

    status_message: [STATUS_BUF_LEN]u8 = [_]u8{0} ** STATUS_BUF_LEN,
    status_timer: f32 = 0,

    /// Toggled by the View menu, the Build menu, and the Compiler Output
    /// module. The module reads this via its `Module.is_open` pointer.
    show_compiler_output: bool = false,
    compiler_output_scroll_to_bottom: bool = false,

    show_project_settings: bool = false,
    project_settings: project_settings_mod.ProjectSettings = .{},

    show_resources: bool = false,
    resources_editor: resources_mod.ResourcesEditor = .{},

    /// Open editor tabs. Each entry is an `OpenTab` (currently only
    /// scene, prefab landing in a follow-up). Populated when the
    /// user clicks an editable file in the project tree; closed via
    /// the × on a tab. `closeAllTabs` runs on project transitions.
    open_tabs: std.ArrayList(OpenTab) = .{},
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
    /// Last seen `ProjectManager.generation`. Compared each frame so
    /// `closeAllTabs` runs the frame the active project changes.
    last_project_generation: ?u64 = null,

    /// Per-project atlas index (sprite name → frame + GL texture).
    /// Built lazily the first frame the active project's generation
    /// is observed; invalidated when the generation bumps. Inspector
    /// + viewport consult it to validate `sprite_name` and draw the
    /// real pixels for entities with a Sprite component.
    atlas_index: ?atlas.Index = null,

    show_project_tree: bool = true,

    show_new_scene_dialog: bool = false,
    new_scene_name: [SCENE_NAME_BUF_LEN:0]u8 = [_:0]u8{0} ** SCENE_NAME_BUF_LEN,
    show_dpi_warning: bool = false,

    /// Fixed-size storage for registered modules. Grow the array literal
    /// when adding modules; Zig will tell you if it overflows.
    modules: [4]module.Module = undefined,
    registry: module.Registry = .{ .modules = &.{} },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !*Self {
        const app = try allocator.create(Self);
        errdefer allocator.destroy(app);

        app.* = .{
            .allocator = allocator,
            .window = window,
            .project_manager = project.ProjectManager.init(allocator),
            .tree_view = tree_view.TreeView.init(allocator),
            .compiler = compiler.Compiler.init(allocator),
        };

        app.modules[0] = project_tree_mod.makeModule(app);
        app.modules[1] = compiler_output.makeModule(app);
        app.modules[2] = project_settings_mod.makeModule(app);
        app.modules[3] = resources_mod.makeModule(app);
        app.registry = .{ .modules = &app.modules };

        return app;
    }

    pub fn deinit(self: *Self) void {
        self.closeAllTabs();
        self.open_tabs.deinit(self.allocator);
        if (self.atlas_index) |*idx| idx.deinit();
        self.project_manager.deinit();
        self.tree_view.deinit();
        self.compiler.deinit();
        self.allocator.destroy(self);
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
        var resources: std.ArrayList(atlas.Resource) = .{};
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
        try self.open_tabs.append(self.allocator, .{ .prefab = state });
        const new_idx = self.open_tabs.items.len - 1;
        self.active_tab_idx = new_idx;
        self.focus_tab_idx = new_idx;
    }

    /// Close the tab at `idx` unconditionally. Caller asks the user
    /// about unsaved changes via `requestCloseTab` first.
    pub fn closeTab(self: *Self, idx: usize) void {
        if (idx >= self.open_tabs.items.len) return;
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

    /// One UI frame. `dt_seconds` is the wall-clock time since the last
    /// frame, used to decrement transient timers (status messages, etc.)
    /// so they last a consistent duration regardless of frame rate.
    /// Caller is responsible for `backend.newFrame`/`backend.draw`
    /// around this; the test harness needs that boundary to inject events.
    pub fn renderFrame(self: *Self, dt_seconds: f32) void {
        if (self.status_timer > 0) self.status_timer -= dt_seconds;

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
            }
        } else {
            self.rebuildAtlasIndex();
        }
        self.last_project_generation = gen;

        self.renderMenuBar();
        self.pollCompiler();
        self.renderMainContent();
        self.registry.renderAllPanels(self);
        self.renderStatusBar();
        new_scene_dialog.render(self);
        close_scene_dialog.render(self);
        dpi_warning_dialog.render(self);
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

    // ─── Panels ─────────────────────────────────────────────────────────

    fn renderMainContent(self: *Self) void {
        const viewport = zgui.getMainViewport();
        const work_pos = viewport.getWorkPos();
        const work_size = viewport.getWorkSize();
        zgui.setNextWindowPos(.{ .x = work_pos[0] + config.ui.sidebar_width, .y = work_pos[1] });
        zgui.setNextWindowSize(.{ .w = work_size[0] - config.ui.sidebar_width, .h = work_size[1] - config.ui.status_bar_height });

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
