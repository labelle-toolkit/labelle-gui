const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const nfd = @import("nfd");
const project = @import("project.zig");
const tree_view = @import("tree_view.zig");
const icons = @import("icons.zig");
const config = @import("config.zig");

const gl = zopengl.bindings;

const AppState = struct {
    project_manager: project.ProjectManager,
    tree_view: tree_view.TreeView,
    status_message: [256]u8 = [_]u8{0} ** 256,
    status_timer: f32 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize GLFW
    zglfw.init() catch {
        std.log.err("Failed to initialize GLFW", .{});
        return error.GlfwInitFailed;
    };
    defer zglfw.terminate();

    // Set window hints for OpenGL
    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);

    // Create window
    const window = zglfw.createWindow(1280, 720, "Labelle", null) catch {
        std.log.err("Failed to create GLFW window", .{});
        return error.WindowCreationFailed;
    };
    defer window.destroy();

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);

    // Load OpenGL
    zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3) catch {
        std.log.err("Failed to load OpenGL", .{});
        return error.OpenGLLoadFailed;
    };

    // Initialize ImGui
    zgui.init(allocator);
    defer zgui.deinit();

    const scale_factor = window.getContentScale()[0];
    const font_size = config.ui.base_font_size * scale_factor;

    // Add default font
    _ = zgui.io.addFontDefault(null);

    // Add FontAwesome icons (merged into the default font)
    var fa_config = zgui.FontConfig.init();
    fa_config.merge_mode = true;
    fa_config.pixel_snap_h = true;
    fa_config.glyph_min_advance_x = font_size; // Fixed width for icons
    _ = zgui.io.addFontFromFileWithConfig(
        "assets/fonts/fa-solid-900.ttf",
        font_size,
        fa_config,
        &icons.FA_ICON_RANGES,
    );
    // Note: Font loading errors are handled internally by zgui/ImGui

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    // Initialize app state
    var state = AppState{
        .project_manager = project.ProjectManager.init(allocator),
        .tree_view = tree_view.TreeView.init(allocator),
    };
    defer state.project_manager.deinit();
    defer state.tree_view.deinit();

    std.debug.print("Labelle started!\n", .{});

    // Main loop
    while (!window.shouldClose()) {
        zglfw.pollEvents();

        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        // Update status timer
        if (state.status_timer > 0) {
            state.status_timer -= 1.0 / 60.0; // Assuming 60fps
        }

        // Main menu bar
        if (zgui.beginMainMenuBar()) {
            if (zgui.beginMenu("File", true)) {
                if (zgui.menuItem("New Project...", .{})) {
                    // Open folder picker to select where to create project
                    if (nfd.openFolderDialog(null)) |maybe_path| {
                        if (maybe_path) |folder_path| {
                            defer nfd.freePath(folder_path);
                            // Create new project with folder name as project name
                            const name = std.fs.path.basename(folder_path);
                            state.project_manager.newProject(name) catch |err| {
                                std.debug.print("Error creating project: {}\n", .{err});
                                setStatus(&state, "Error creating project!");
                            };
                            // Auto-save to the selected folder
                            const save_path = std.fmt.allocPrint(allocator, "{s}/project", .{folder_path}) catch {
                                setStatus(&state, "Memory error!");
                                continue;
                            };
                            defer allocator.free(save_path);
                            state.project_manager.saveProject(save_path) catch |err| {
                                std.debug.print("Error saving project: {}\n", .{err});
                                setStatus(&state, "Error saving project!");
                            };
                            setStatus(&state, "New project created!");
                            state.tree_view.refresh();
                        }
                    } else |_| {
                        setStatus(&state, "Error opening folder dialog!");
                    }
                }
                if (zgui.menuItem("Open Project...", .{})) {
                    // Open file picker for .labelle files
                    if (nfd.openFileDialog("labelle", null)) |maybe_path| {
                        if (maybe_path) |file_path| {
                            defer nfd.freePath(file_path);
                            state.project_manager.loadProject(file_path) catch |err| {
                                std.debug.print("Error loading project: {}\n", .{err});
                                setStatus(&state, "Error loading project!");
                            };
                            setStatus(&state, "Project loaded!");
                            state.tree_view.refresh();
                        }
                    } else |_| {
                        setStatus(&state, "Error opening file dialog!");
                    }
                }
                zgui.separator();
                if (zgui.menuItem("Save", .{})) {
                    if (state.project_manager.current_project) |proj| {
                        if (proj.path) |path| {
                            state.project_manager.saveProject(path) catch |err| {
                                setStatus(&state, "Error saving project!");
                                std.debug.print("Save error: {}\n", .{err});
                            };
                            setStatus(&state, "Project saved!");
                        } else {
                            // No path yet, use Save As
                            if (nfd.saveFileDialog("labelle", null)) |maybe_path| {
                                if (maybe_path) |file_path| {
                                    defer nfd.freePath(file_path);
                                    state.project_manager.saveProject(file_path) catch |err| {
                                        std.debug.print("Save error: {}\n", .{err});
                                        setStatus(&state, "Error saving project!");
                                    };
                                    setStatus(&state, "Project saved!");
                                }
                            } else |_| {
                                setStatus(&state, "Error opening save dialog!");
                            }
                        }
                    }
                }
                if (zgui.menuItem("Save As...", .{})) {
                    if (state.project_manager.current_project != null) {
                        if (nfd.saveFileDialog("labelle", null)) |maybe_path| {
                            if (maybe_path) |file_path| {
                                defer nfd.freePath(file_path);
                                state.project_manager.saveProject(file_path) catch |err| {
                                    std.debug.print("Save error: {}\n", .{err});
                                    setStatus(&state, "Error saving project!");
                                };
                                setStatus(&state, "Project saved!");
                            }
                        } else |_| {
                            setStatus(&state, "Error opening save dialog!");
                        }
                    }
                }
                zgui.separator();
                if (zgui.menuItem("Close Project", .{})) {
                    state.project_manager.closeProject();
                    setStatus(&state, "Project closed");
                }
                zgui.separator();
                if (zgui.menuItem("Exit", .{})) {
                    window.setShouldClose(true);
                }
                zgui.endMenu();
            }
            if (zgui.beginMenu("Help", true)) {
                if (zgui.menuItem("About", .{})) {}
                zgui.endMenu();
            }
            zgui.endMainMenuBar();
        }

        // Main window
        const viewport = zgui.getMainViewport();
        const work_pos = viewport.getWorkPos();
        const work_size = viewport.getWorkSize();

        // Left sidebar - Project Tree View
        zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] });
        zgui.setNextWindowSize(.{ .w = config.ui.sidebar_width, .h = work_size[1] - config.ui.status_bar_height });

        if (zgui.begin("Project", .{
            .flags = .{
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
            },
        })) {
            if (state.project_manager.current_project) |proj| {
                // Get project directory
                const project_dir = proj.getProjectDir();

                // Render tree view
                if (state.tree_view.render(project_dir)) {
                    // File was selected
                    if (state.tree_view.getSelectedPath()) |selected| {
                        std.debug.print("Selected: {s}\n", .{selected});
                    }
                }
            } else {
                zgui.textDisabled("No project open", .{});
            }
        }
        zgui.end();

        // Main content area
        zgui.setNextWindowPos(.{ .x = work_pos[0] + config.ui.sidebar_width, .y = work_pos[1] });
        zgui.setNextWindowSize(.{ .w = work_size[0] - config.ui.sidebar_width, .h = work_size[1] - config.ui.status_bar_height });

        if (zgui.begin("##main", .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
                .menu_bar = false,
            },
        })) {
            if (state.project_manager.current_project) |proj| {
                // Project is open
                zgui.text("Project: {s}", .{proj.metadata.name});
                if (proj.is_dirty) {
                    zgui.sameLine(.{});
                    zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
                }

                zgui.separator();

                // Show selected file info
                if (state.tree_view.getSelectedPath()) |selected| {
                    zgui.text("Selected: {s}", .{std.fs.path.basename(selected)});
                    zgui.separator();
                }

                zgui.text("Ready to work!", .{});
            } else {
                // No project open
                zgui.text("Welcome to Labelle!", .{});
                zgui.spacing();
                zgui.text("Create a new project or open an existing one.", .{});
                zgui.spacing();

                if (zgui.button("New Project...", .{ .w = 150 })) {
                    if (nfd.openFolderDialog(null)) |maybe_path| {
                        if (maybe_path) |folder_path| {
                            defer nfd.freePath(folder_path);
                            const name = std.fs.path.basename(folder_path);
                            state.project_manager.newProject(name) catch |err| {
                                std.debug.print("Error creating project: {}\n", .{err});
                                setStatus(&state, "Error creating project!");
                            };
                            const save_path = std.fmt.allocPrint(allocator, "{s}/project", .{folder_path}) catch {
                                setStatus(&state, "Memory error!");
                                continue;
                            };
                            defer allocator.free(save_path);
                            state.project_manager.saveProject(save_path) catch |err| {
                                std.debug.print("Error saving project: {}\n", .{err});
                                setStatus(&state, "Error saving project!");
                            };
                            setStatus(&state, "New project created!");
                            state.tree_view.refresh();
                        }
                    } else |_| {
                        setStatus(&state, "Error opening folder dialog!");
                    }
                }
                if (zgui.button("Open Project...", .{ .w = 150 })) {
                    if (nfd.openFileDialog("labelle", null)) |maybe_path| {
                        if (maybe_path) |file_path| {
                            defer nfd.freePath(file_path);
                            state.project_manager.loadProject(file_path) catch |err| {
                                std.debug.print("Error loading project: {}\n", .{err});
                                setStatus(&state, "Error loading project!");
                            };
                            setStatus(&state, "Project loaded!");
                            state.tree_view.refresh();
                        }
                    } else |_| {
                        setStatus(&state, "Error opening file dialog!");
                    }
                }
            }
        }
        zgui.end();

        // Status bar at bottom
        zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] + work_size[1] - config.ui.status_bar_height });
        zgui.setNextWindowSize(.{ .w = work_size[0], .h = config.ui.status_bar_height });

        if (zgui.begin("##statusbar", .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_collapse = true,
                .no_scrollbar = true,
            },
        })) {
            if (state.status_timer > 0) {
                const status = std.mem.sliceTo(&state.status_message, 0);
                zgui.text("{s}", .{status});
            } else {
                if (state.project_manager.current_project) |proj| {
                    if (proj.path) |path| {
                        zgui.text("{s}", .{path});
                    } else {
                        zgui.text("Unsaved project", .{});
                    }
                } else {
                    zgui.text("No project open", .{});
                }
            }
        }
        zgui.end();

        // Render
        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.draw();

        window.swapBuffers();
    }

    std.debug.print("Labelle closed.\n", .{});
}

fn setStatus(state: *AppState, message: []const u8) void {
    @memset(&state.status_message, 0);
    @memcpy(state.status_message[0..message.len], message);
    state.status_timer = config.ui.status_message_duration;
}
