//! `InspectorSection` — one collapsing-header section in the entity
//! inspector. Mirrors the Module/Registry pattern in `../../module.zig`:
//! each typed component lives in its own file under `inspector/`, exports
//! a `section()` constructor, and the parent `inspector.zig` just iterates
//! a comptime-fixed array.
//!
//! The trailing "Other components (N)" group isn't modeled here because
//! it doesn't read a typed field on `Entity` — it walks an extras slice.
//! It stays special-cased in `inspector.zig`.

const scene_io = @import("../../scene_io.zig");
const atlas = @import("../../atlas.zig");

pub const InspectorSection = struct {
    /// Collapsing-header label. Must be a stable C string for imgui.
    name: [:0]const u8,
    /// Initial open state for the section's collapsing header.
    default_open: bool = false,
    /// True when the section applies to `entity` — e.g. the Sprite
    /// section only renders when `entity.sprite != null`. Position
    /// is always present (it renders a "(no Position component)"
    /// hint when the field is null).
    is_present: *const fn (*scene_io.Entity) bool,
    /// Body of the section. The caller has already opened the
    /// collapsing header; this just paints into it.
    render: *const fn (
        entity: *scene_io.Entity,
        is_dirty: *bool,
        atlas_index: ?*const atlas.Index,
    ) void,
};
