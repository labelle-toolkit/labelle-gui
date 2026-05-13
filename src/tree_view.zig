const std = @import("std");
const zgui = @import("zgui");
const project = @import("project.zig");
const icons = @import("icons.zig");

/// Icons for each folder type (FontAwesome icons)
pub const FolderIcons = struct {
    pub const components = icons.FA_CUBE; // 3D cube for components
    pub const fixtures = icons.FA_WRENCH; // Wrench for fixtures
    pub const gizmos = icons.FA_BULLSEYE; // Bullseye for gizmos
    pub const prefabs = icons.FA_BOX; // Box for prefabs
    pub const scenes = icons.FA_FILM; // Film for scenes
    pub const scripts = icons.FA_SCROLL; // Scroll for scripts
    pub const scripts_flows = icons.FA_PROJECT_DIAGRAM; // Graph icon for flows
    pub const resources = icons.FA_DATABASE; // Database for resources
    pub const file = icons.FA_FILE; // File icon
    pub const folder_open = icons.FA_FOLDER_OPEN; // Open folder
    pub const folder_closed = icons.FA_FOLDER; // Closed folder

    pub fn forFolder(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, project.ProjectFolders.components)) return components;
        if (std.mem.eql(u8, name, project.ProjectFolders.fixtures)) return fixtures;
        if (std.mem.eql(u8, name, project.ProjectFolders.gizmos)) return gizmos;
        if (std.mem.eql(u8, name, project.ProjectFolders.prefabs)) return prefabs;
        if (std.mem.eql(u8, name, project.ProjectFolders.scenes)) return scenes;
        if (std.mem.eql(u8, name, project.ProjectFolders.scripts)) return scripts;
        // The Flows folder is nested under `scripts/` and registered
        // in `ProjectFolders.all` as the literal `"scripts/flows"`.
        // Match the full path here so the lookup hits.
        if (std.mem.eql(u8, name, project.ProjectFolders.scripts_flows)) return scripts_flows;
        if (std.mem.eql(u8, name, project.ProjectFolders.resources)) return resources;
        return folder_closed;
    }
};

/// Represents a file entry in the tree
pub const FileEntry = struct {
    name: []const u8,
    is_directory: bool,
};

/// Cache entry for folder contents
const CacheEntry = struct {
    entries: []FileEntry,
};

/// TreeView component for displaying project files
pub const TreeView = struct {
    allocator: std.mem.Allocator,
    selected_path: ?[]const u8,
    cached_files: std.StringHashMap(CacheEntry),
    needs_refresh: bool,

    const Self = @This();

    /// Max bytes for the on-stack path buffers used during render +
    /// recursion. We deliberately do NOT use `std.fs.max_path_bytes`
    /// here — it's ~96 KiB on Windows (vs 4 KiB on POSIX), and the
    /// recursive walker plus the per-folder `managed_storage` array
    /// would blow the default 1 MiB Windows thread stack the moment
    /// any subfolder expanded (bugbot #70 high). 4 KiB covers any
    /// realistic project path on every platform; longer paths get
    /// skipped rather than crashing.
    const path_buf_size: usize = 4096;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .selected_path = null,
            .cached_files = std.StringHashMap(CacheEntry).init(allocator),
            .needs_refresh = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.selected_path) |path| {
            self.allocator.free(path);
        }
        self.clearCache();
        self.cached_files.deinit();
    }

    fn clearCache(self: *Self) void {
        var it = self.cached_files.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.entries) |file_entry| {
                self.allocator.free(file_entry.name);
            }
            self.allocator.free(entry.value_ptr.entries);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cached_files.clearRetainingCapacity();
    }

    /// Mark tree view for refresh (call when files change)
    pub fn refresh(self: *Self) void {
        self.needs_refresh = true;
    }

    /// Get the currently selected file path
    pub fn getSelectedPath(self: *const Self) ?[]const u8 {
        return self.selected_path;
    }

    /// Render the tree view widget
    /// Returns true if a file was selected
    pub fn render(self: *Self, project_path: ?[]const u8) bool {
        var file_selected = false;

        if (project_path == null) {
            zgui.textDisabled("No project open", .{});
            return false;
        }

        const base_path = project_path.?;

        // Refresh cache if needed
        if (self.needs_refresh) {
            self.clearCache();
            self.needs_refresh = false;
        }

        // Precompute absolute paths of every managed top-level folder. The
        // recursive walker uses these to skip subdirectories that are
        // ALREADY rendered as separate top-level entries — namely
        // `scripts/flows`, which appears in `ProjectFolders.all` as a
        // sibling of `scripts`. Without this, recursing into `scripts`
        // would surface `flows/` a second time with the wrong icon.
        var managed_storage: [project.ProjectFolders.all.len][path_buf_size]u8 = undefined;
        var managed_paths: [project.ProjectFolders.all.len][]const u8 = undefined;
        for (project.ProjectFolders.all, 0..) |fname, i| {
            managed_paths[i] = std.fmt.bufPrint(&managed_storage[i], "{s}/{s}", .{ base_path, fname }) catch "";
        }

        // Render each project folder (using stack buffers to avoid heap allocations per frame)
        for (project.ProjectFolders.all) |folder_name| {
            const icon = FolderIcons.forFolder(folder_name);

            // Build folder path on stack
            var folder_path_buf: [path_buf_size]u8 = undefined;
            const folder_path = std.fmt.bufPrint(&folder_path_buf, "{s}/{s}", .{ base_path, folder_name }) catch continue;

            // Create tree node label directly on stack
            var node_label: [256:0]u8 = undefined;
            _ = std.fmt.bufPrintZ(&node_label, "{s} {s}", .{ icon, folder_name }) catch continue;

            const node_open = zgui.treeNodeFlags(&node_label, .{ .span_full_width = true });

            if (node_open) {
                if (self.renderFolder(folder_path, &managed_paths)) {
                    file_selected = true;
                }
                zgui.treePop();
            }
        }

        return file_selected;
    }

    /// Render the contents of a single directory. Recurses into subdirectories
    /// (each becomes its own `treeNodeFlags`) so the user can drill arbitrarily
    /// deep. Files at any depth render as `zgui.selectable` and route through
    /// `self.selected_path` exactly like top-level files do. Subdirectories
    /// whose absolute path matches a `managed_paths` entry are suppressed —
    /// they're already rendered at top level (see `render`).
    fn renderFolder(self: *Self, folder_path: []const u8, managed_paths: []const []const u8) bool {
        var file_selected = false;

        const files = self.getFilesForFolder(folder_path) catch {
            zgui.textDisabled("  (error reading folder)", .{});
            return false;
        };

        if (files.len == 0) {
            zgui.textDisabled("  (empty)", .{});
            return false;
        }

        for (files) |file_entry| {
            // Single null-terminated full-path buffer covers all three
            // uses: routing (`selected_path`), the managed-path dedup
            // check, and the ImGui string ID (so identically named
            // children of different parents — e.g. scenes/enemies vs
            // prefabs/enemies — get distinct open/closed state).
            var full_path_buf: [path_buf_size:0]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ folder_path, file_entry.name }) catch continue;

            // Skip subdirectories that are already top-level entries.
            if (file_entry.is_directory) {
                var is_managed = false;
                for (managed_paths) |mp| {
                    if (mp.len != 0 and std.mem.eql(u8, mp, full_path)) {
                        is_managed = true;
                        break;
                    }
                }
                if (is_managed) continue;
            }

            var label_buf: [512:0]u8 = undefined;
            const file_icon = if (file_entry.is_directory) FolderIcons.folder_closed else FolderIcons.file;
            const label = std.fmt.bufPrintZ(&label_buf, "{s} {s}", .{ file_icon, file_entry.name }) catch continue;

            zgui.pushStrIdZ(full_path);
            defer zgui.popId();

            if (file_entry.is_directory) {
                if (zgui.treeNodeFlags(label, .{ .span_full_width = true })) {
                    if (self.renderFolder(full_path, managed_paths)) {
                        file_selected = true;
                    }
                    zgui.treePop();
                }
            } else {
                // File rows render as `selectable`, which starts at the row's
                // left edge. Subfolder rows above them use `treeNodeFlags`,
                // whose label sits to the right of the chevron column
                // (FontSize + 2*FramePadding.x). Without a matching indent
                // here, the file icon column lands flush against the parent
                // indent while subfolder icon columns sit one chevron-width
                // further right — the chevron then looks "attached" to the
                // file row above instead of belonging to its own subfolder.
                // Issue #73 acceptance: file + subfolder icons aligned inside
                // the same parent.
                const indent_w = zgui.getFontSize() + zgui.getStyle().frame_padding[0] * 2.0;
                zgui.indent(.{ .indent_w = indent_w });
                defer zgui.unindent(.{ .indent_w = indent_w });

                const is_selected = if (self.selected_path) |sel|
                    std.mem.eql(u8, sel, full_path)
                else
                    false;

                if (zgui.selectable(label, .{ .selected = is_selected })) {
                    if (self.selected_path) |old_path| {
                        self.allocator.free(old_path);
                    }
                    self.selected_path = self.allocator.dupe(u8, full_path) catch null;
                    file_selected = true;
                }
            }
        }

        return file_selected;
    }

    fn getFilesForFolder(self: *Self, folder_path: []const u8) ![]const FileEntry {
        // Check cache first
        if (self.cached_files.get(folder_path)) |cache_entry| {
            return cache_entry.entries;
        }

        // Read directory and collect entries
        var temp_entries: std.ArrayListUnmanaged(FileEntry) = .empty;
        defer temp_entries.deinit(self.allocator);

        var dir = std.fs.cwd().openDir(folder_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                // Folder doesn't exist yet - that's okay
                const empty_entries = try self.allocator.alloc(FileEntry, 0);
                const key = try self.allocator.dupe(u8, folder_path);
                try self.cached_files.put(key, .{ .entries = empty_entries });
                return empty_entries;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Skip hidden files
            if (entry.name[0] == '.') continue;

            const name_copy = try self.allocator.dupe(u8, entry.name);
            try temp_entries.append(self.allocator, .{
                .name = name_copy,
                .is_directory = entry.kind == .directory,
            });
        }

        // Sort entries: directories first, then alphabetically
        std.mem.sort(FileEntry, temp_entries.items, {}, struct {
            fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
                if (a.is_directory != b.is_directory) {
                    return a.is_directory; // directories first
                }
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        // Copy to owned slice for cache
        const entries = try self.allocator.dupe(FileEntry, temp_entries.items);
        const key = try self.allocator.dupe(u8, folder_path);
        try self.cached_files.put(key, .{ .entries = entries });
        return entries;
    }
};
