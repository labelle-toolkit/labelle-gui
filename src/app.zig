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

const STATUS_BUF_LEN = 256;
const SCENE_NAME_BUF_LEN = 128;

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

    show_new_scene_dialog: bool = false,
    new_scene_name: [SCENE_NAME_BUF_LEN:0]u8 = [_:0]u8{0} ** SCENE_NAME_BUF_LEN,
    show_dpi_warning: bool = false,

    /// Fixed-size storage for registered modules. Grow the array literal
    /// when adding modules; Zig will tell you if it overflows.
    modules: [1]module.Module = undefined,
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

        app.modules[0] = compiler_output.makeModule(app);
        app.registry = .{ .modules = &app.modules };

        return app;
    }

    pub fn deinit(self: *Self) void {
        self.project_manager.deinit();
        self.tree_view.deinit();
        self.compiler.deinit();
        self.allocator.destroy(self);
    }

    pub fn setStatus(self: *Self, message: []const u8) void {
        @memset(&self.status_message, 0);
        const n = @min(message.len, self.status_message.len - 1);
        @memcpy(self.status_message[0..n], message[0..n]);
        self.status_timer = config.ui.status_message_duration;
    }

    /// One UI frame. Caller is responsible for `backend.newFrame`/`backend.draw`
    /// around this; the test harness needs that boundary to inject events.
    pub fn renderFrame(self: *Self) void {
        if (self.status_timer > 0) self.status_timer -= 1.0 / 60.0;

        self.renderMenuBar();
        self.pollCompiler();
        self.renderProjectSidebar();
        self.renderMainContent();
        self.registry.renderAllPanels(self);
        self.renderStatusBar();
        self.renderNewSceneDialog();
        self.renderDpiWarning();
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

    fn renderProjectSidebar(self: *Self) void {
        const viewport = zgui.getMainViewport();
        const work_pos = viewport.getWorkPos();
        const work_size = viewport.getWorkSize();
        zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] });
        zgui.setNextWindowSize(.{ .w = config.ui.sidebar_width, .h = work_size[1] - config.ui.status_bar_height });

        if (zgui.begin("Project", .{ .flags = .{ .no_resize = true, .no_move = true, .no_collapse = true } })) {
            if (self.project_manager.current_project) |proj| {
                _ = self.tree_view.render(proj.getProjectDir());
            } else {
                zgui.textDisabled("No project open", .{});
            }
        }
        zgui.end();
    }

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

        if (self.project_manager.current_project) |proj| {
            zgui.text("Project: {s}", .{proj.config.name});
            if (proj.is_dirty) {
                zgui.sameLine(.{});
                zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
            }
            zgui.separator();
            if (self.tree_view.getSelectedPath()) |selected| {
                zgui.text("Selected: {s}", .{std.fs.path.basename(selected)});
                zgui.separator();
            }
            zgui.text("Ready to work!", .{});
        } else {
            zgui.text("Welcome to Labelle!", .{});
            zgui.spacing();
            zgui.text("Create a new project or open an existing one.", .{});
            zgui.spacing();
            if (zgui.button("New Project...", .{ .w = 150 })) self.pickFolderAndCreateProject();
            if (zgui.button("Open Project...", .{ .w = 150 })) self.pickFolderAndOpenProject();
        }
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

    fn renderNewSceneDialog(self: *Self) void {
        if (self.show_new_scene_dialog) zgui.openPopup("New Scene", .{});
        if (!zgui.beginPopupModal("New Scene", .{ .popen = &self.show_new_scene_dialog, .flags = .{ .always_auto_resize = true } })) return;
        defer zgui.endPopup();

        zgui.text("Enter scene name:", .{});
        zgui.spacing();
        if (zgui.isWindowAppearing()) zgui.setKeyboardFocusHere(0);

        const enter_pressed = zgui.inputText("##scene_name", .{
            .buf = &self.new_scene_name,
            .flags = .{ .enter_returns_true = true },
        });

        zgui.spacing();
        zgui.separator();
        zgui.spacing();

        if (zgui.button("Create", .{ .w = 120 }) or enter_pressed) {
            const scene_name = std.mem.sliceTo(&self.new_scene_name, 0);
            if (scene_name.len > 0) self.createScene(scene_name);
            zgui.closeCurrentPopup();
            self.show_new_scene_dialog = false;
        }
        zgui.sameLine(.{});
        if (zgui.button("Cancel", .{ .w = 120 })) {
            zgui.closeCurrentPopup();
            self.show_new_scene_dialog = false;
        }
    }

    fn createScene(self: *Self, scene_name: []const u8) void {
        const proj = self.project_manager.current_project orelse return;
        const proj_dir = proj.getProjectDir() orelse return;

        var path_buf: [512]u8 = undefined;
        const scene_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.scene", .{
            proj_dir,
            project.ProjectFolders.scenes,
            scene_name,
        }) catch {
            self.setStatus("Path too long!");
            return;
        };

        const file = std.fs.cwd().createFile(scene_path, .{ .exclusive = true }) catch |err| {
            self.setStatus(if (err == error.PathAlreadyExists) "Scene already exists!" else "Error creating scene!");
            return;
        };
        defer file.close();

        var content_buf: [512]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf,
            \\# {s}
            \\# Scene created by Labelle GUI
            \\
            \\[scene]
            \\name = "{s}"
            \\
            \\[entities]
            \\# Define your entities here
            \\
        , .{ scene_name, scene_name }) catch {
            self.setStatus("Error formatting scene content!");
            return;
        };
        file.writeAll(content) catch {
            self.setStatus("Error writing scene file!");
            return;
        };
        self.setStatus("Scene created!");
        self.tree_view.refresh();
    }

    fn renderDpiWarning(self: *Self) void {
        if (self.show_dpi_warning) zgui.openPopup("Display Scale Changed", .{});
        if (!zgui.beginPopupModal("Display Scale Changed", .{
            .popen = &self.show_dpi_warning,
            .flags = .{ .always_auto_resize = true },
        })) return;
        defer zgui.endPopup();

        zgui.text("The display scale has changed.", .{});
        zgui.text("For best results, please restart the application.", .{});
        zgui.spacing();
        zgui.separator();
        zgui.spacing();
        if (zgui.button("OK", .{ .w = 120 })) self.show_dpi_warning = false;
    }
};
