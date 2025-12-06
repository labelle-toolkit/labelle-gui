const std = @import("std");
const zgui = @import("zgui");
const project = @import("project.zig");

/// Icons for each folder type (Unicode)
pub const FolderIcons = struct {
    pub const models = "\u{1F3AD}"; // 🎭 Theater masks for 3D models
    pub const fixtures = "\u{1F527}"; // 🔧 Wrench for fixtures
    pub const prefabs = "\u{1F4E6}"; // 📦 Package for prefabs
    pub const scripts = "\u{1F4DC}"; // 📜 For scripts
    pub const resources = "\u{1F4C1}"; // 📁 Folder for resources
    pub const file = "\u{1F4C4}"; // 📄 Document for files
    pub const folder_open = "\u{1F4C2}"; // 📂 Open folder
    pub const folder_closed = "\u{1F4C1}"; // 📁 Closed folder

    pub fn forFolder(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, project.ProjectFolders.models)) return models;
        if (std.mem.eql(u8, name, project.ProjectFolders.fixtures)) return fixtures;
        if (std.mem.eql(u8, name, project.ProjectFolders.prefabs)) return prefabs;
        if (std.mem.eql(u8, name, project.ProjectFolders.scripts)) return scripts;
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

        // Render each project folder
        for (project.ProjectFolders.all) |folder_name| {
            const icon = FolderIcons.forFolder(folder_name);

            // Build folder path
            const folder_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, folder_name }) catch continue;
            defer self.allocator.free(folder_path);

            // Create tree node with icon
            const node_label_slice = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ icon, folder_name }) catch continue;
            defer self.allocator.free(node_label_slice);

            // Create sentinel-terminated string for zgui
            var node_label: [256:0]u8 = [_:0]u8{0} ** 256;
            const copy_len = @min(node_label_slice.len, 255);
            @memcpy(node_label[0..copy_len], node_label_slice[0..copy_len]);

            const node_open = zgui.treeNodeFlags(&node_label, .{});

            if (node_open) {
                // Load and display files in this folder
                const files = self.getFilesForFolder(folder_path) catch {
                    zgui.textDisabled("  (error reading folder)", .{});
                    zgui.treePop();
                    continue;
                };

                if (files.len == 0) {
                    zgui.textDisabled("  (empty)", .{});
                } else {
                    for (files) |file_entry| {
                        const file_icon = if (file_entry.is_directory) FolderIcons.folder_closed else FolderIcons.file;
                        const file_label_slice = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ file_icon, file_entry.name }) catch continue;
                        defer self.allocator.free(file_label_slice);

                        // Create sentinel-terminated string for zgui
                        var file_label: [256:0]u8 = [_:0]u8{0} ** 256;
                        const file_copy_len = @min(file_label_slice.len, 255);
                        @memcpy(file_label[0..file_copy_len], file_label_slice[0..file_copy_len]);

                        // Check if this file is selected
                        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ folder_path, file_entry.name }) catch continue;
                        defer self.allocator.free(full_path);

                        const is_selected = if (self.selected_path) |sel|
                            std.mem.eql(u8, sel, full_path)
                        else
                            false;

                        if (zgui.selectable(&file_label, .{ .selected = is_selected })) {
                            // Update selected path
                            if (self.selected_path) |old_path| {
                                self.allocator.free(old_path);
                            }
                            self.selected_path = self.allocator.dupe(u8, full_path) catch null;
                            file_selected = true;
                        }
                    }
                }

                zgui.treePop();
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
