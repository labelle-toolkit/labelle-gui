const std = @import("std");
const zgui = @import("zgui");
const project = @import("project.zig");
const icons = @import("icons.zig");

/// Icons for each folder type (FontAwesome icons)
/// Centralized icon set for the tree view. Every folder — top-level or
/// nested — renders with the same `folder` glyph so the icon column
/// reads consistently across the whole tree (issue #73). The chevron is
/// the sole open/closed indicator. File rows use a single `file` glyph.
pub const FolderIcons = struct {
    pub const file = icons.FA_FILE;
    pub const folder = icons.FA_FOLDER;
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
    /// Set of expanded directory paths (top-level + nested). All rows —
    /// folders and files — render as `zgui.selectable`, which is the
    /// only way to guarantee folder and file selection bars have
    /// identical height. ImGui's `TreeNodeFlags` uses a different
    /// height formula (`FontSize + 2*FramePadding.y`) than `Selectable`
    /// (`FontSize + ItemSpacing.y` after the bb spacing extension), so
    /// the two widget types render visibly different bars. Owning the
    /// open/closed state here lets us draw the disclosure caret as part
    /// of the selectable's label glyph run.
    open_dirs: std.StringHashMap(void),
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
            .open_dirs = std.StringHashMap(void).init(allocator),
            .needs_refresh = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.selected_path) |path| {
            self.allocator.free(path);
        }
        self.clearCache();
        self.cached_files.deinit();
        self.clearOpenDirs();
        self.open_dirs.deinit();
    }

    fn clearOpenDirs(self: *Self) void {
        var it = self.open_dirs.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.open_dirs.clearRetainingCapacity();
    }

    fn isOpen(self: *const Self, path: []const u8) bool {
        return self.open_dirs.contains(path);
    }

    fn toggleOpen(self: *Self, path: []const u8) void {
        if (self.open_dirs.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            return;
        }
        const owned = self.allocator.dupe(u8, path) catch return;
        self.open_dirs.put(owned, {}) catch self.allocator.free(owned);
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

        // Render each project folder
        for (project.ProjectFolders.all) |folder_name| {
            // Build folder path on stack
            var folder_path_buf: [path_buf_size:0]u8 = undefined;
            const folder_path = std.fmt.bufPrintZ(&folder_path_buf, "{s}/{s}", .{ base_path, folder_name }) catch continue;

            if (self.renderDirectoryRow(folder_path, folder_name, &managed_paths)) {
                file_selected = true;
            }
        }

        return file_selected;
    }

    /// Render one directory row (selectable with caret + folder icon) and
    /// recurse into its contents when the directory is in `open_dirs`.
    /// Drives both top-level project folders and nested subdirectories so
    /// every directory row in the tree uses the same widget — no
    /// height/spacing drift between depths. Click toggles open/closed
    /// state; the row never becomes `selected_path` (only files do).
    fn renderDirectoryRow(
        self: *Self,
        folder_path: [:0]const u8,
        display_name: []const u8,
        managed_paths: []const []const u8,
    ) bool {
        var file_selected = false;
        const is_open_state = self.isOpen(folder_path);
        const caret = if (is_open_state) icons.FA_CARET_DOWN else icons.FA_CARET_RIGHT;

        var label_buf: [512:0]u8 = undefined;
        const label = std.fmt.bufPrintZ(
            &label_buf,
            "{s}{s} {s}",
            .{ caret, FolderIcons.folder, display_name },
        ) catch return false;

        zgui.pushStrIdZ(folder_path);
        defer zgui.popId();

        // Capture the row's leading screen-X *before* the selectable: this
        // is the caret column, where the vertical guide line for the
        // open-children block needs to drop from.
        const parent_screen_x = zgui.getCursorScreenPos()[0];

        if (zgui.selectable(label, .{})) {
            self.toggleOpen(folder_path);
        }

        if (self.isOpen(folder_path)) {
            zgui.indent(.{});
            defer zgui.unindent(.{});

            const line_top_y = zgui.getCursorScreenPos()[1];
            if (self.renderFolder(folder_path, managed_paths)) {
                file_selected = true;
            }
            const line_bottom_y = zgui.getCursorScreenPos()[1];

            // Vertical guide line sits over the caret glyph itself.
            // FA_CARET_RIGHT / FA_CARET_DOWN are drawn left-aligned
            // within their `glyph_min_advance_x = font_size` advance box
            // (see main.zig) and span roughly 35-40% of that box, so the
            // caret's visual center sits ~0.3 * font_size from the row's
            // leading edge. Color comes from the imgui theme so it
            // tracks dark/light style switches.
            const draw_list = zgui.getWindowDrawList();
            const color_u32 = zgui.colorConvertFloat4ToU32(
                zgui.getStyle().getColor(.tree_lines),
            );
            const line_x = parent_screen_x + zgui.getFontSize() * 0.4;
            draw_list.addLine(.{
                .p1 = .{ line_x, line_top_y },
                .p2 = .{ line_x, line_bottom_y },
                .col = color_u32,
                .thickness = 1.0,
            });
        }

        return file_selected;
    }

    /// Render the contents of an opened directory. Each child renders as
    /// a single `selectable` — directories route through
    /// `renderDirectoryRow` so they share the same widget + height as
    /// files. Subdirectories whose absolute path matches a
    /// `managed_paths` entry are suppressed because they're already
    /// rendered at top level (e.g. `scripts/flows`).
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

            if (file_entry.is_directory) {
                if (self.renderDirectoryRow(full_path, file_entry.name, managed_paths)) {
                    file_selected = true;
                }
            } else {
                var label_buf: [512:0]u8 = undefined;
                // No leading space — files have no caret column, so their
                // icon sits at the row's leading edge (where a directory's
                // caret would be). Matches the VS Code-style file tree
                // alignment: file icon column == directory caret column,
                // file name column == directory folder-icon column.
                const label = std.fmt.bufPrintZ(
                    &label_buf,
                    "{s} {s}",
                    .{ FolderIcons.file, file_entry.name },
                ) catch continue;

                zgui.pushStrIdZ(full_path);
                defer zgui.popId();

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
