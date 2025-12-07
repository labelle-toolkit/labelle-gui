const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const nfd = @import("nfd");
const project = @import("project.zig");
const tree_view = @import("tree_view.zig");
const icons = @import("icons.zig");
const config = @import("config.zig");
const compiler = @import("compiler.zig");

const gl = zopengl.bindings;

// Configure logging level for the application
pub const std_options: std.Options = .{
    .log_level = .info,
};

// DPI handling constants
const dpi_epsilon: f32 = 1e-6;
const dpi_change_threshold: f32 = 0.05; // 5% change considered significant

// DPI state for handling dynamic scale changes
var g_initial_scale: f32 = 1.0;
var g_current_scale: std.atomic.Value(f32) = std.atomic.Value(f32).init(1.0);
var g_dpi_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn contentScaleCallback(_: *zglfw.Window, xscale: f32, _: f32) callconv(.c) void {
    g_current_scale.store(xscale, .release);
    g_dpi_changed.store(true, .release);
}

const AppState = struct {
    project_manager: project.ProjectManager,
    tree_view: tree_view.TreeView,
    compiler: compiler.Compiler,
    status_message: [256]u8 = [_]u8{0} ** 256,
    status_timer: f32 = 0,
    show_compiler_output: bool = false,
    compiler_output_scroll_to_bottom: bool = false,
    // New scene dialog
    show_new_scene_dialog: bool = false,
    new_scene_name: [128:0]u8 = [_:0]u8{0} ** 128,
    // DPI change notification
    show_dpi_warning: bool = false,
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

    // Disable ini file to avoid memory leak warning on exit
    zgui.io.setIniFilename(null);

    const scale_factor = window.getContentScale()[0];

    // Store initial scale and set up callback for dynamic DPI changes
    g_initial_scale = scale_factor;
    g_current_scale.store(scale_factor, .release);
    _ = window.setContentScaleCallback(contentScaleCallback);
    const font_size = config.ui.base_font_size * scale_factor;

    // Add default font at scaled size for Retina displays
    var default_config = zgui.FontConfig.init();
    default_config.size_pixels = font_size;
    _ = zgui.io.addFontDefault(default_config);

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

    // Scale UI elements for high-DPI displays
    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    // Initialize app state
    var state = AppState{
        .project_manager = project.ProjectManager.init(allocator),
        .tree_view = tree_view.TreeView.init(allocator),
        .compiler = compiler.Compiler.init(allocator),
    };
    defer state.project_manager.deinit();
    defer state.tree_view.deinit();
    defer state.compiler.deinit();

    std.log.info("Labelle started", .{});

    // Main loop
    while (!window.shouldClose()) {
        zglfw.pollEvents();

        // Check for DPI changes (e.g., window moved to monitor with different scale)
        if (g_dpi_changed.swap(false, .acquire)) {
            const new_scale = g_current_scale.load(.acquire);
            // Only show warning if scale changed significantly
            if (g_initial_scale > dpi_epsilon and @abs(new_scale - g_initial_scale) / g_initial_scale > dpi_change_threshold) {
                state.show_dpi_warning = true;
            }
        }

        // Pass window size (not framebuffer size) to ImGui for correct mouse coordinates
        // The backend sets framebuffer scale to 1.0, so we need window coordinates
        const win_size = window.getSize();
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(win_size[0]), @intCast(win_size[1]));

        // Manually set the correct framebuffer scale for Retina displays
        const fb_scale_x = @as(f32, @floatFromInt(fb_size[0])) / @as(f32, @floatFromInt(win_size[0]));
        const fb_scale_y = @as(f32, @floatFromInt(fb_size[1])) / @as(f32, @floatFromInt(win_size[1]));
        zgui.io.setDisplayFramebufferScale(fb_scale_x, fb_scale_y);

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
                                std.log.err("Error creating project: {}", .{err});
                                setStatus(&state, "Error creating project!");
                            };
                            // Auto-save to the selected folder
                            const save_path = std.fmt.allocPrint(allocator, "{s}/project", .{folder_path}) catch {
                                setStatus(&state, "Memory error!");
                                continue;
                            };
                            defer allocator.free(save_path);
                            state.project_manager.saveProject(save_path) catch |err| {
                                std.log.err("Error saving project: {}", .{err});
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
                                std.log.err("Error loading project: {}", .{err});
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
                if (zgui.menuItem("New Scene...", .{ .enabled = state.project_manager.current_project != null })) {
                    state.show_new_scene_dialog = true;
                    @memset(&state.new_scene_name, 0);
                }
                zgui.separator();
                if (zgui.menuItem("Save", .{})) {
                    if (state.project_manager.current_project) |proj| {
                        if (proj.path) |path| {
                            state.project_manager.saveProject(path) catch |err| {
                                setStatus(&state, "Error saving project!");
                                std.log.err("Save error: {}", .{err});
                            };
                            setStatus(&state, "Project saved!");
                        } else {
                            // No path yet, use Save As
                            if (nfd.saveFileDialog("labelle", null)) |maybe_path| {
                                if (maybe_path) |file_path| {
                                    defer nfd.freePath(file_path);
                                    state.project_manager.saveProject(file_path) catch |err| {
                                        std.log.err("Save error: {}", .{err});
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
                                    std.log.err("Save error: {}", .{err});
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
            if (zgui.beginMenu("Build", state.project_manager.current_project != null)) {
                const can_build = state.compiler.isIdle();
                if (zgui.menuItem("Generate Build Files", .{ .enabled = can_build })) {
                    if (state.project_manager.current_project) |proj| {
                        if (state.compiler.generateAllBuildFiles(proj)) {
                            setStatus(&state, "Build files generated!");
                            state.tree_view.refresh();
                        } else |err| {
                            std.log.err("Error generating build files: {}", .{err});
                            setStatus(&state, "Error generating build files!");
                        }
                    }
                }
                zgui.separator();
                if (zgui.menuItem("Build", .{ .enabled = can_build })) {
                    if (state.project_manager.current_project) |proj| {
                        // First ensure build files exist
                        const gen_ok = if (state.compiler.generateAllBuildFiles(proj)) true else |err| blk: {
                            std.log.err("Error generating build files: {}", .{err});
                            setStatus(&state, "Error generating build files!");
                            break :blk false;
                        };
                        if (gen_ok) {
                            if (state.compiler.build(proj)) {
                                setStatus(&state, "Building...");
                                state.show_compiler_output = true;
                                state.compiler_output_scroll_to_bottom = true;
                            } else |err| {
                                std.log.err("Error starting build: {}", .{err});
                                setStatus(&state, "Error starting build!");
                            }
                        }
                    }
                }
                if (zgui.menuItem("Run", .{ .enabled = can_build })) {
                    if (state.project_manager.current_project) |proj| {
                        if (state.compiler.run(proj)) {
                            setStatus(&state, "Running game...");
                        } else |err| {
                            std.log.err("Error running game: {}", .{err});
                            setStatus(&state, "Error running game!");
                        }
                    }
                }
                zgui.separator();
                if (zgui.menuItem("Show Output", .{ .selected = state.show_compiler_output })) {
                    state.show_compiler_output = !state.show_compiler_output;
                }
                zgui.endMenu();
            }
            if (zgui.beginMenu("Help", true)) {
                if (zgui.menuItem("About", .{})) {}
                zgui.endMenu();
            }
            zgui.endMainMenuBar();
        }

        // Poll compiler for build completion
        if (state.compiler.pollBuild()) |result| {
            if (result.success) {
                setStatus(&state, "Build successful!");
            } else {
                setStatus(&state, "Build failed!");
            }
            state.compiler_output_scroll_to_bottom = true;
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
                        std.log.debug("Selected: {s}", .{selected});
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
                                std.log.err("Error creating project: {}", .{err});
                                setStatus(&state, "Error creating project!");
                            };
                            const save_path = std.fmt.allocPrint(allocator, "{s}/project", .{folder_path}) catch {
                                setStatus(&state, "Memory error!");
                                continue;
                            };
                            defer allocator.free(save_path);
                            state.project_manager.saveProject(save_path) catch |err| {
                                std.log.err("Error saving project: {}", .{err});
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
                                std.log.err("Error loading project: {}", .{err});
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

        // Compiler output panel (shown when building or when user toggles it)
        const compiler_output_height: f32 = if (state.show_compiler_output) 200 else 0;
        if (state.show_compiler_output) {
            zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] + work_size[1] - config.ui.status_bar_height - compiler_output_height });
            zgui.setNextWindowSize(.{ .w = work_size[0], .h = compiler_output_height });

            if (zgui.begin("Compiler Output", .{
                .popen = &state.show_compiler_output,
                .flags = .{
                    .no_resize = true,
                    .no_move = true,
                    .no_collapse = true,
                },
            })) {
                // Show compiler state
                const compiler_state = state.compiler.getState();
                switch (compiler_state) {
                    .idle => zgui.textDisabled("Ready", .{}),
                    .generating => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Generating...", .{}),
                    .building => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Building...", .{}),
                    .running => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Running...", .{}),
                    .success => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Success", .{}),
                    .failed => zgui.textColored(.{ 1.0, 0.0, 0.0, 1.0 }, "Failed", .{}),
                }
                zgui.separator();

                // Show output/errors
                if (zgui.beginChild("##output", .{ .h = -1 })) {
                    if (state.compiler.last_result) |result| {
                        if (result.errors.len > 0) {
                            zgui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "{s}", .{result.errors});
                        }
                        if (result.output.len > 0) {
                            zgui.text("{s}", .{result.output});
                        }
                    } else {
                        zgui.textDisabled("No output", .{});
                    }

                    // Auto-scroll to bottom
                    if (state.compiler_output_scroll_to_bottom) {
                        zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
                        state.compiler_output_scroll_to_bottom = false;
                    }
                }
                zgui.endChild();
            }
            zgui.end();
        }

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

        // New Scene Dialog
        if (state.show_new_scene_dialog) {
            zgui.openPopup("New Scene", .{});
        }
        if (zgui.beginPopupModal("New Scene", .{ .popen = &state.show_new_scene_dialog, .flags = .{ .always_auto_resize = true } })) {
            zgui.text("Enter scene name:", .{});
            zgui.spacing();

            // Auto-focus the input field when dialog opens
            if (zgui.isWindowAppearing()) {
                zgui.setKeyboardFocusHere(0);
            }

            const enter_pressed = zgui.inputText("##scene_name", .{ .buf = &state.new_scene_name, .flags = .{ .enter_returns_true = true } });

            zgui.spacing();
            zgui.separator();
            zgui.spacing();

            if (zgui.button("Create", .{ .w = 120 }) or enter_pressed) {
                const scene_name = std.mem.sliceTo(&state.new_scene_name, 0);
                if (scene_name.len > 0) {
                    if (state.project_manager.current_project) |proj| {
                        if (proj.getProjectDir()) |proj_dir| {
                            // Create scene file
                            var path_buf: [512]u8 = undefined;
                            const scene_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.scene", .{
                                proj_dir,
                                project.ProjectFolders.scenes,
                                scene_name,
                            }) catch {
                                setStatus(&state, "Path too long!");
                                zgui.closeCurrentPopup();
                                state.show_new_scene_dialog = false;
                                zgui.endPopup();
                                continue;
                            };

                            // Create the scene file
                            const file = std.fs.cwd().createFile(scene_path, .{ .exclusive = true }) catch |err| {
                                if (err == error.PathAlreadyExists) {
                                    setStatus(&state, "Scene already exists!");
                                } else {
                                    setStatus(&state, "Error creating scene!");
                                }
                                zgui.closeCurrentPopup();
                                state.show_new_scene_dialog = false;
                                zgui.endPopup();
                                continue;
                            };
                            defer file.close();

                            // Write default scene content
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
                                setStatus(&state, "Error formatting scene content!");
                                state.show_new_scene_dialog = false;
                                zgui.endPopup();
                                continue;
                            };
                            file.writeAll(content) catch {
                                setStatus(&state, "Error writing scene file!");
                                state.show_new_scene_dialog = false;
                                zgui.endPopup();
                                continue;
                            };

                            setStatus(&state, "Scene created!");
                            state.tree_view.refresh();
                        }
                    }
                    zgui.closeCurrentPopup();
                    state.show_new_scene_dialog = false;
                }
            }
            zgui.sameLine(.{});
            if (zgui.button("Cancel", .{ .w = 120 })) {
                zgui.closeCurrentPopup();
                state.show_new_scene_dialog = false;
            }

            zgui.endPopup();
        }

        // DPI Change Warning Dialog
        if (state.show_dpi_warning) {
            zgui.openPopup("Display Scale Changed", .{});
        }
        if (zgui.beginPopupModal("Display Scale Changed", .{ .popen = &state.show_dpi_warning, .flags = .{ .always_auto_resize = true } })) {
            zgui.text("The display scale has changed.", .{});
            zgui.text("For best results, please restart the application.", .{});
            zgui.spacing();
            zgui.separator();
            zgui.spacing();

            if (zgui.button("OK", .{ .w = 120 * g_initial_scale })) {
                state.show_dpi_warning = false;
            }
            zgui.endPopup();
        }

        // Render
        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.draw();

        window.swapBuffers();
    }

    std.log.info("Labelle closed", .{});
}

fn setStatus(state: *AppState, message: []const u8) void {
    @memset(&state.status_message, 0);
    @memcpy(state.status_message[0..message.len], message);
    state.status_timer = config.ui.status_message_duration;
}
