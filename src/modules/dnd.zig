//! Drag-and-drop payload type for custom components being dragged
//! from the project tree's `components/` folder onto a prefab
//! editor's canvas (#143). This is the smallest possible slice that
//! enables "drag a component → drop it as a child of an open prefab"
//! — future PRs add prefab payloads and scene-canvas targets on top.
//!
//! ImGui's drag-drop API takes:
//!   - A short `[:0]const u8` payload identifier (≤ 32 chars).
//!   - An arbitrary byte buffer the source `set`s and the target
//!     `accept`s. ImGui copies the bytes into its own context-owned
//!     buffer, so the payload struct must be plain-data (no pointers
//!     back into caller memory) and sized for the largest realistic
//!     value the source might emit.

const std = @import("std");

/// Payload identifier for a component dragged from the project tree.
/// The component is identified by its filename stem; the engine uses
/// the stem as the component type name. Source and target MUST agree
/// on this literal — ImGui filters `accept` calls against it so two
/// drag-drop kinds can coexist without cross-firing.
pub const COMPONENT_TYPE: [:0]const u8 = "labelle_component_name";

/// Largest component-stem byte length we'll carry through a drag.
/// OS-level filename limits are well under this; the cap is the
/// safety net for a malformed source. 128 covers everything realistic.
pub const PAYLOAD_NAME_CAP: usize = 128;

/// Plain-data payload carried by a component drag. Same shape as
/// future payloads will use — fixed-size `extern struct`, no sentinel-
/// terminated array (Zig 0.16 is strict about those in `extern`),
/// length tracked explicitly via `name_len`.
pub const ComponentPayload = extern struct {
    /// Valid prefix length of `name`. Always ≤ PAYLOAD_NAME_CAP.
    name_len: u8,
    /// Zero-padded component stem bytes (e.g. "bed", "storage").
    name: [PAYLOAD_NAME_CAP]u8,
};

/// Build a payload from a caller-supplied component stem. Truncates
/// if the stem is longer than `PAYLOAD_NAME_CAP` — callers shouldn't
/// see stems that long in practice (OS path limits), but the clamp
/// keeps us robust against a malformed tree entry.
pub fn packComponent(stem: []const u8) ComponentPayload {
    var p: ComponentPayload = .{ .name_len = 0, .name = [_]u8{0} ** PAYLOAD_NAME_CAP };
    const n = @min(stem.len, PAYLOAD_NAME_CAP);
    @memcpy(p.name[0..n], stem[0..n]);
    p.name_len = @intCast(n);
    return p;
}

/// Read the component stem back out of a received payload. Returns a
/// slice into the payload buffer — caller must not retain it past
/// the drop callback (ImGui's payload buffer is reused).
pub fn unpackComponent(payload: *const ComponentPayload) []const u8 {
    return payload.name[0..payload.name_len];
}

/// Payload identifier for a prefab `.jsonc` file dragged from the
/// project tree onto a scene viewport (issue #85). The prefab is
/// identified by its filename stem (e.g. "canteen") — the same key
/// the engine uses when a scene entity writes
/// `{ "prefab": "canteen" }`. Distinct from `COMPONENT_TYPE` so the
/// two drag kinds can coexist without the wrong target accepting
/// the wrong payload.
pub const PREFAB_TYPE: [:0]const u8 = "labelle_prefab_name";

/// Plain-data payload carried by a prefab drag. Same fixed-buffer
/// shape as `ComponentPayload` so the two share `PAYLOAD_NAME_CAP`
/// and the receive-side `@memcpy` pattern is identical. We carry
/// the *stem* (basename minus `.jsonc`), not the absolute path —
/// the engine + `prefab_index` both key on stem, and a stem is
/// always shorter than the OS-level path it came from.
pub const PrefabPayload = extern struct {
    /// Valid prefix length of `name`. Always ≤ PAYLOAD_NAME_CAP.
    name_len: u8,
    /// Zero-padded prefab stem bytes (e.g. "canteen", "movement_node").
    name: [PAYLOAD_NAME_CAP]u8,
};

/// Build a prefab payload from a caller-supplied stem. Truncates if
/// the stem exceeds `PAYLOAD_NAME_CAP` — OS path limits make that
/// effectively impossible, but the clamp keeps us robust against a
/// malformed tree entry.
pub fn packPrefab(stem: []const u8) PrefabPayload {
    var p: PrefabPayload = .{ .name_len = 0, .name = [_]u8{0} ** PAYLOAD_NAME_CAP };
    const n = @min(stem.len, PAYLOAD_NAME_CAP);
    @memcpy(p.name[0..n], stem[0..n]);
    p.name_len = @intCast(n);
    return p;
}

/// Read the prefab stem back out of a received payload. Returns a
/// slice into the payload buffer — caller must dupe before the
/// next imgui frame.
pub fn unpackPrefab(payload: *const PrefabPayload) []const u8 {
    return payload.name[0..payload.name_len];
}
