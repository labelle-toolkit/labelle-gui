//! zspec Factory definitions shared across tests.
//!
//! Pattern recap (informs #109/#120 follow-up work):
//!
//!   * `Factory.defineFrom(T, @import("…zon"))` — concise, fixture in
//!     a separate `.zon` file, field-name typo detection at comptime.
//!     Works only when every field of T has a concrete value the zon
//!     literal can coerce to. Slice fields (`[]const X = &.{}`) hit the
//!     `@as(FieldType, .{})` coercion path and fail to compile, so
//!     reserve `defineFrom` for leaf types like `ResourceDef`.
//!
//!   * `Factory.define(T, .{ ...defaults })` — same comptime defaults,
//!     authored in Zig source. Necessary when T has slice or pointer
//!     fields because we can write `&.{}` and `@as([]const X, &.{})`
//!     explicitly. Use for outer types like `ProjectConfig`.
//!
//! Strings inside the defaults are static (comptime). `.build({})`
//! returns a value whose strings outlive any test arena, so the
//! resulting `ResourceDef` / `ProjectConfig` can be assigned directly
//! to a project arena-owned slice without per-field `dupe()` ceremony.
const zspec = @import("zspec");
const Factory = zspec.Factory;
const project = @import("project.zig");

const resource_zon = @import("test_fixtures/resource.zon");

pub const ResourceFactory = Factory.defineFrom(project.ResourceDef, resource_zon);

pub const ProjectConfigFactory = Factory.define(project.ProjectConfig, .{
    .name = "factory_project",
    .description = "",
    .title = "Factory Project",
    .width = 1280,
    .height = 720,
    .target_fps = 60,
    .backend = .raylib,
    .ecs = .zig_ecs,
    .initial_scene = "main",
    .core_version = "1.12.0",
    .engine_version = "1.35.0",
    .gfx_version = "1.10.0",
    .assembler_version = "0.17.0",
    .resources = @as([]const project.ResourceDef, &.{}),
});
