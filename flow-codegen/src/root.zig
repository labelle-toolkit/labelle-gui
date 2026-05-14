//! Public surface of the `flow_codegen` sub-package.
//!
//! Lives inside `labelle-gui` (mirroring `labelle-engine`'s
//! `audio_backend` / `labelle-gfx`'s `spatial_grid` sub-packages) so
//! `labelle-assembler` can depend on the pure-Zig `.flow.zon` parser
//! and codegen without pulling in the gui's imgui/zgui stack.
//!
//! The gui-side projector / renderers / types modules stay in
//! `labelle-gui/src/flows/` — they consume `std.zig.Ast` for the
//! Zig-to-graph projector and have nothing to do with the on-disk
//! schema. Only the schema-shaped pieces are promoted here.
//!
//! See `labelle-gui#94` for the tracking issue.

pub const flow_io = @import("flow_io.zig");
pub const codegen = @import("codegen.zig");
