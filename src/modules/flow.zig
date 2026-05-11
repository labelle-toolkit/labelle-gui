//! Flow editor — per-tab state and rendering for visual-scripting
//! "flow graph" `.flow.zon` files under `<project>/scripts/flows/`.
//!
//! Phase 0 (spike — issue #45 / umbrella #42): prove we can embed
//! [thedmd/imgui-node-editor](https://github.com/thedmd/imgui-node-editor)
//! as a tab inside labelle-gui. This file is intentionally minimal:
//!
//!   - One `EditorContext` per tab (owned by `FlowState`, destroyed
//!     in `deinit`).
//!   - A single placeholder node with one input + one output pin.
//!     The user can drag it; nothing else is wired up.
//!
//! Save / dirty tracking are no-ops for the spike — Phase 1 (issues
//! #46–#52) lands a real `.flow.zon` schema, a node catalog, and
//! serialization. The acceptance criterion here is: linker is
//! happy, canvas renders, node drags.
//!
//! Not registered as a togglable panel; opens as a tab via tree
//! click on a `.flow.zon` file (`project_tree.isFlowPath`).

const std = @import("std");
const zgui = @import("zgui");
const ne = zgui.node_editor;

const App = @import("../app.zig").App;
const scene_io = @import("../scene_io.zig");

/// Pin IDs are global within an editor context; tag the placeholder
/// node's pins with distinct constants so the editor can tell them
/// apart. NodeId is `u64` per the zgui binding — 0 is reserved
/// internally as "no node", so start at 1.
const placeholder_node_id: u64 = 1;
const placeholder_input_pin_id: u64 = 100;
const placeholder_output_pin_id: u64 = 101;

pub const FlowState = struct {
    /// Owns `path` and `display_name`. No parsed-source arena for
    /// the spike — the file isn't actually read.
    arena: *std.heap.ArenaAllocator,
    /// Absolute path on disk. Used for dedup when opening another
    /// tab on the same file. Not actually read or written.
    path: []const u8,
    /// Filename stem without `.flow.zon`. Used for the tab label.
    display_name: []const u8,
    /// imgui-node-editor's per-canvas state. Holds the visual
    /// position of every node, current selection, view transform,
    /// etc. Owned by this tab; destroyed in `deinit`.
    editor: *ne.EditorContext,
    /// Spike has no real edits to dirty-flag. Always false so the
    /// close-tab modal never fires. Phase 1 will wire this up to
    /// real edits.
    is_dirty: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FlowState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = displayNameFromPath(path_dup);

        // Spike: don't persist the node layout — pass a null
        // `settings_file` so the editor keeps its layout in memory
        // only. Phase 1 will route the layout through our own ZON
        // save callbacks.
        const config: ne.Config = .{};
        const editor = ne.EditorContext.create(config);

        return .{
            .arena = arena,
            .path = path_dup,
            .display_name = display_name,
            .editor = editor,
        };
    }

    pub fn deinit(self: *FlowState, allocator: std.mem.Allocator) void {
        self.editor.destroy();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// `foo.flow.zon` → `foo`. Strip both extensions so the tab label
/// matches the user's mental file name. Falls back to the basename
/// when the path doesn't end in our expected suffix.
fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".flow.zon";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return scene_io.displayNameFromPath(path);
}

pub fn render(s: *FlowState, app: *App) void {
    _ = app;
    zgui.text("Flow: {s}", .{s.display_name});
    zgui.sameLine(.{});
    zgui.textDisabled("(spike — no save, no schema, no node catalog yet)", .{});
    zgui.separator();

    // Bind the per-tab editor context for the duration of this
    // frame. SetCurrentEditor must wrap every Begin/End — the
    // editor is global state inside thedmd's library.
    ne.setCurrentEditor(s.editor);
    defer ne.setCurrentEditor(null);

    // size = {0,0} → fill the parent's content region.
    ne.begin("##flow_canvas", .{ 0, 0 });
    defer ne.end();

    // Single placeholder node: input pin on the left, output pin
    // on the right. The editor places the node on first frame; the
    // user can drag it after that.
    ne.beginNode(placeholder_node_id);
    zgui.text("Placeholder", .{});
    ne.beginPin(placeholder_input_pin_id, .input);
    zgui.text("-> in", .{});
    ne.endPin();
    zgui.sameLine(.{});
    ne.beginPin(placeholder_output_pin_id, .output);
    zgui.text("out ->", .{});
    ne.endPin();
    ne.endNode();
}

/// No-op for the spike. The Flow tab is never dirty, so the close
/// modal never reaches this path; but `OpenTab.save` still needs
/// a function to dispatch to.
pub fn saveFlow(s: *FlowState, app: *App) void {
    _ = s;
    _ = app;
}
