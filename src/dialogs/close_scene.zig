//! Confirmation modal shown when the user tries to close a tab that
//! has unsaved edits. Driven by `App.pending_close_idx` — non-null
//! means "the tab at this index has been ×'d and is dirty; ask the
//! user what to do." Three resolutions:
//!
//! - **Save and close**: writes the scene back to disk via the Scene
//!   module's `saveScene` and then drops the tab.
//! - **Discard**: drops the tab without writing.
//! - **Cancel**: keeps the tab open; `pending_close_idx` is cleared
//!   so subsequent close attempts re-fire the dialog.

const zgui = @import("zgui");

const App = @import("../app.zig").App;
const scene_mod = @import("../modules/scene.zig");

pub fn render(app: *App) void {
    const idx = app.pending_close_idx orelse return;
    if (idx >= app.open_scenes.items.len) {
        // Tab was already gone (e.g. closeAllScenes ran between
        // request and dialog render). Drop the request silently.
        app.pending_close_idx = null;
        return;
    }
    const state = &app.open_scenes.items[idx];

    zgui.openPopup("Unsaved scene", .{});
    if (!zgui.beginPopupModal("Unsaved scene", .{ .flags = .{ .always_auto_resize = true } })) return;
    defer zgui.endPopup();

    zgui.text("Scene \"{s}\" has unsaved changes.", .{state.display_name});
    zgui.text("Save before closing?", .{});
    zgui.spacing();
    zgui.separator();
    zgui.spacing();

    if (zgui.button("Save and close", .{ .w = 150 })) {
        scene_mod.saveScene(state, app);
        if (!state.is_dirty) {
            // Save succeeded — close.
            app.closeScene(idx);
        }
        // If save_scene failed, is_dirty stays true; status bar already
        // surfaces the error. Keep the dialog dismissed so the user
        // can investigate without it re-firing on the next frame.
        app.pending_close_idx = null;
        zgui.closeCurrentPopup();
    }
    zgui.sameLine(.{});
    if (zgui.button("Discard", .{ .w = 100 })) {
        app.closeScene(idx);
        app.pending_close_idx = null;
        zgui.closeCurrentPopup();
    }
    zgui.sameLine(.{});
    if (zgui.button("Cancel", .{ .w = 100 })) {
        app.pending_close_idx = null;
        zgui.closeCurrentPopup();
    }
}
