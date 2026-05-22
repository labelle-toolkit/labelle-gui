//! Shared atlas → imgui binding helpers.
//!
//! `viewport.zig` and `game_view.zig` both resolve a sprite name to a
//! GL texture id + UV sub-rect by hand; `inspector.zig` flags missing
//! sprites. This module centralises the resolve + UV math so any panel
//! can bind an atlas frame to a `zgui` widget (`image`, `imageButton`,
//! `addImage`) without re-deriving it.
//!
//! Lifetime note: a `Resolved` is built fresh from the live
//! `atlas.Index` and must never be cached across frames. The index is
//! keyed by `ProjectManager.generation` and freed on project
//! new/load/close — a stashed `TextureRef` would dangle. Always
//! re-resolve from the current `App.atlas_index` each frame.

const std = @import("std");
const zgui = @import("zgui");
const atlas = @import("atlas.zig");

/// A sprite frame resolved against a live atlas index: everything a
/// `zgui` image-family call needs to draw that one frame.
pub const Resolved = struct {
    tex_ref: zgui.TextureRef,
    uv0: [2]f32,
    uv1: [2]f32,
    /// Frame pixel dimensions — handy for aspect-correct sizing.
    frame_w: u32,
    frame_h: u32,
};

/// Resolve `sprite_name` against `index` into a `TextureRef` + UV rect.
/// Returns `null` when the index is absent, the name is empty/unknown,
/// or the owning atlas has no GL texture — callers fall back to a
/// non-image widget in that case.
pub fn resolve(index: ?*const atlas.Index, sprite_name: []const u8) ?Resolved {
    const idx = index orelse return null;
    if (sprite_name.len == 0) return null;
    const ref = idx.find(sprite_name) orelse return null;

    const tex_id = idx.textureFor(ref);
    if (tex_id == 0) return null;
    const size = idx.atlasSize(ref);

    const uv0: [2]f32 = .{
        @as(f32, @floatFromInt(ref.frame.x)) / size[0],
        @as(f32, @floatFromInt(ref.frame.y)) / size[1],
    };
    const uv1: [2]f32 = .{
        @as(f32, @floatFromInt(ref.frame.x + ref.frame.w)) / size[0],
        @as(f32, @floatFromInt(ref.frame.y + ref.frame.h)) / size[1],
    };

    // ImGui 1.92+ TextureRef: a null `tex_data` tells the opengl3
    // backend to read the raw handle in `tex_id` directly — exactly
    // what we want for atlas textures we manage ourselves.
    return .{
        .tex_ref = .{ .tex_data = null, .tex_id = @enumFromInt(@as(u64, tex_id)) },
        .uv0 = uv0,
        .uv1 = uv1,
        .frame_w = ref.frame.w,
        .frame_h = ref.frame.h,
    };
}

/// An `imageButton` showing the atlas frame for `sprite_name`, sized
/// `w`×`h`. Falls back to a plain text button (the sprite name, or
/// `"(sprite)"` when empty) when the atlas index is null or the sprite
/// can't be resolved. Returns true on the frame it was clicked.
///
/// `str_id` must be unique among sibling widgets — image content
/// carries no implicit imgui ID, so two image buttons sharing a
/// `str_id` would merge their click/hover state.
pub fn spriteButton(
    str_id: [:0]const u8,
    index: ?*const atlas.Index,
    sprite_name: []const u8,
    w: f32,
    h: f32,
) bool {
    if (resolve(index, sprite_name)) |r| {
        return zgui.imageButton(str_id, r.tex_ref, .{
            .w = w,
            .h = h,
            .uv0 = r.uv0,
            .uv1 = r.uv1,
        });
    }
    return textFallbackButton(str_id, sprite_name, w, h);
}

/// Text-button fallback shared by `spriteButton`. The visible label is
/// the sprite name (or `"(sprite)"` when empty); the imgui ID is forced
/// to `str_id` via the `label##id` suffix so callers keep a stable,
/// unique ID regardless of the (possibly duplicated) sprite name.
fn textFallbackButton(str_id: [:0]const u8, sprite_name: []const u8, w: f32, h: f32) bool {
    var label_buf: [192]u8 = undefined;
    const visible = if (sprite_name.len == 0) "(sprite)" else sprite_name;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}##{s}", .{ visible, str_id }) catch str_id;
    return zgui.button(label, .{ .w = w, .h = h });
}
