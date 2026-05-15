//! Tests for the `flow_codegen` sub-package — the `.flow.zon` parser
//! and the graph-to-Zig codegen pass.
//!
//! BDD-style tests using `zspec`, mirroring the convention used in
//! `labelle-gfx`'s `spatial_grid` sub-package. Tests originally lived
//! in `labelle-gui/src/tests.zig` (as `FlowIoTests` / `FlowCodegenTests`)
//! and moved here verbatim when the sub-package was promoted in
//! `labelle-gui#94`.

const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const flow_codegen_pkg = @import("flow_codegen");

const flow_io = flow_codegen_pkg.flow_io;
const flow_codegen = flow_codegen_pkg.codegen;

test {
    zspec.runAll(@This());
}

pub const FlowIoTests = struct {
    // The sketch from issue #46 — the canonical example a flow file
    // looks like in v1. Used by the round-trip test below.
    const sample_issue_46 =
        \\.{
        \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
        \\    .nodes = .{
        \\        .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
        \\        .{ .id = 2, .pos = .{280, 80}, .kind = .{ .BinOp = .{ .op = .add } } },
        \\        .{ .id = 3, .pos = .{440, 80}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
        \\    },
        \\    .links = .{
        \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
        \\    },
        \\}
        \\
    ;

    const minimal_on_update =
        \\.{
        \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
        \\    .nodes = .{},
        \\    .links = .{},
        \\}
        \\
    ;

    test "parses minimal flow with OnUpdate event" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator, minimal_on_update);
        defer loaded.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnUpdate);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.event.OnUpdate.arg_dt, "dt"));
        try expect.equal(loaded.flow.nodes.len, 0);
        try expect.equal(loaded.flow.links.len, 0);
    }

    test "parses each NodeKind variant" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\        .{ .id = 5, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 6, .pos = .{0, 0}, .kind = .{ .Call = .{ .callee = "std.math.sin" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        try expect.equal(loaded.flow.nodes.len, 6);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .GetComponent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.GetComponent.type, "Position"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .SetField);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.SetField.target, "Position.x"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[2].kind), .BinOp);
        try expect.equal(loaded.flow.nodes[2].kind.BinOp.op, .mul);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[3].kind), .Literal);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[3].kind.Literal.value, "1.5"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[4].kind), .Identifier);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[4].kind.Identifier.name, "speed"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[5].kind), .Call);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[5].kind.Call.callee, "std.math.sin"));
    }

    test "parses each Event variant" {
        const allocator = std.testing.allocator;

        const on_create =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "self" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        var l1 = try flow_io.parseFlow(allocator, on_create);
        defer l1.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l1.flow.event), .OnCreate);
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.event.OnCreate.arg_entity, "self"));

        const on_destroy =
            \\.{
            \\    .event = .{ .OnDestroy = .{ .arg_entity = "victim" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        var l2 = try flow_io.parseFlow(allocator, on_destroy);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnDestroy);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnDestroy.arg_entity, "victim"));
    }

    test "round-trips example from #46 structurally" {
        // The renderer's output is canonical (sorted, indented) so a
        // byte-equal compare to the hand-authored source would fight
        // the spec. Instead, parse -> render -> parse and confirm the
        // structural shape matches.
        const allocator = std.testing.allocator;

        var l1 = try flow_io.parseFlow(allocator, sample_issue_46);
        defer l1.deinit();

        const rendered = try flow_io.renderFlowZon(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnUpdate);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnUpdate.arg_dt, "dt"));

        try expect.equal(l2.flow.nodes.len, 3);
        try expect.equal(l2.flow.nodes[0].id, 1);
        try expect.equal(l2.flow.nodes[0].pos[0], @as(f32, 120));
        try expect.equal(l2.flow.nodes[0].pos[1], @as(f32, 80));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), l2.flow.nodes[0].kind), .GetComponent);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.nodes[0].kind.GetComponent.type, "Position"));

        try expect.equal(l2.flow.nodes[1].id, 2);
        try expect.equal(l2.flow.nodes[1].kind.BinOp.op, .add);

        try expect.equal(l2.flow.nodes[2].id, 3);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.nodes[2].kind.SetField.target, "Position.x"));

        try expect.equal(l2.flow.links.len, 1);
        try expect.equal(l2.flow.links[0].from.node, 1);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.links[0].from.pin, "x"));
        try expect.equal(l2.flow.links[0].to.node, 2);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.links[0].to.pin, "a"));

        // And the rendered output should re-render byte-identically
        // (idempotent canonicalization).
        const rendered2 = try flow_io.renderFlowZon(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "rejects duplicate node IDs" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "b" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        try std.testing.expectError(error.DuplicateNodeId, flow_io.parseFlow(allocator, src));
    }

    test "rejects link to nonexistent node" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 99, .pin = "y" } },
            \\    },
            \\}
            \\
        ;
        try std.testing.expectError(error.DanglingLink, flow_io.parseFlow(allocator, src));
    }

    test "rejects node id == 0" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 0, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        try std.testing.expectError(error.InvalidNodeId, flow_io.parseFlow(allocator, src));
    }

    test "displayNameFromPath strips .flow.zon" {
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("scripts/flows/move.flow.zon"),
            "move",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("/abs/path/to/jump.flow.zon"),
            "jump",
        ));
        // Bare `.zon` (without the `.flow` infix) is NOT stripped --
        // that's a different file kind and the editor wouldn't open
        // it via this loader anyway.
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("scene.zon"),
            "scene.zon",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("noext"),
            "noext",
        ));
    }

    test "saveFlow + loadFromFile round trip via tmpDir" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "demo.flow.zon" });
        defer allocator.free(path);

        var l1 = try flow_io.parseFlow(allocator, sample_issue_46);
        defer l1.deinit();

        try flow_io.saveFlow(std.testing.io, allocator, path, l1);

        var l2 = try flow_io.loadFromFile(std.testing.io, allocator, path);
        defer l2.deinit();

        try expect.equal(l2.flow.nodes.len, l1.flow.nodes.len);
        try expect.equal(l2.flow.links.len, l1.flow.links.len);
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnUpdate);
    }
};

pub const FlowCodegenTests = struct {
    // Small helper -- parse a ZON source and immediately run codegen,
    // returning the rendered Zig. Frees the parser arena before
    // returning; callers own the returned bytes.
    fn renderFromZon(allocator: std.mem.Allocator, src: []const u8, name: []const u8) ![]u8 {
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        return flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = name });
    }

    test "renders OnUpdate event signature with custom arg_dt name" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "delta" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "demo");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onUpdate(game: *Game, delta: f32) void") != null);
    }

    test "renders OnCreate event signature" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "self" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "spawn");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCreate(game: *Game, self: EntityId) void") != null);
    }

    test "renders OnDestroy event signature" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnDestroy = .{ .arg_entity = "victim" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "cleanup");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onDestroy(game: *Game, victim: EntityId) void") != null);
    }

    test "renders Literal node as a const binding" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "lit");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = 1.5;") != null);
    }

    test "renders Identifier node as a const binding" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 7, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "id");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n7_value = speed;") != null);
    }

    test "renders BinOp node with both inputs connected (distinct producers)" {
        // Regression: a single shared scratch buffer for input
        // resolution would alias `a_expr` and `b_expr` and emit the
        // same identifier twice. Two distinct Literal producers
        // force the renderer to keep both alive simultaneously.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "2" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .sub } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 3, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "b" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "sub");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = n1_value - n2_value;") != null);
    }

    test "renders BinOp node with disconnected pins defaulting to 0" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "binop");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = 0 * 0;") != null);
    }

    test "renders GetComponent node" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "get");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = game.getComponent(entity, Position) orelse return;") != null);
    }

    test "OnCreate with custom arg_entity aliases to entity in template scope" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "self" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "alias");
        defer allocator.free(out);
        // The alias binds the user-chosen parameter name to `entity` so
        // the GetComponent template (which always says `entity`) compiles.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity = self;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "getComponent(entity, Position)") != null);
    }

    test "OnCreate with default arg_entity does not emit redundant alias" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "noalias");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity =") == null);
    }

    test "renders SetField node sourced from a Literal" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "42" } } },
            \\        .{ .id = 5, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 4, .pin = "value" }, .to = .{ .node = 5, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "setf");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n4_value = 42;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n4_value);") != null);
    }

    test "renders Call node with two args" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "2.0" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .Call = .{ .callee = "std.math.atan2" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 3, .pin = "arg0" } },
            \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "arg1" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "call");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = std.math.atan2(n1_value, n2_value);") != null);
    }

    test "topo-sorts dependent nodes correctly" {
        // Literal (id=3) -> BinOp (id=2) -> SetField (id=1). The
        // numeric ids are intentionally in REVERSE topo order so
        // that a naive id-sort would emit the wrong sequence.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "5" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 3, .pin = "value" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 1, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "topo");
        defer allocator.free(out);

        const lit_idx = std.mem.indexOf(u8, out, "const n3_value = 5;") orelse return error.TestExpectedSubstring;
        const binop_idx = std.mem.indexOf(u8, out, "const n2_result = n3_value + 0;") orelse return error.TestExpectedSubstring;
        const set_idx = std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n2_result);") orelse return error.TestExpectedSubstring;
        try expect.toBeTrue(lit_idx < binop_idx);
        try expect.toBeTrue(binop_idx < set_idx);
    }

    test "rejects cycle" {
        const allocator = std.testing.allocator;
        // Two BinOps wired into each other -- node 1's result feeds
        // node 2's `a`, and node 2's result feeds node 1's `a`.
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "result" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 1, .pin = "a" } },
            \\    },
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.CycleDetected,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "cyc" }),
        );
    }

    test "rejects dangling required pin on SetField" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.DanglingPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "missing" }),
        );
    }

    test "rejects unknown pin name on link" {
        const allocator = std.testing.allocator;
        // BinOp has input pins `a` and `b` only -- `c` is unknown.
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "c" } },
            \\    },
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.UnknownPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "bad" }),
        );
    }

    test "injects emitNodeEntered for each node with correct flow_name + id" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 10, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1" } } },
            \\        .{ .id = 20, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "x" } } },
            \\        .{ .id = 30, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "2" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "pulse");
        defer allocator.free(out);

        // The total number of emitNodeEntered calls should equal the
        // node count.
        const haystack = out;
        var count: usize = 0;
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, haystack, search_start, "emitNodeEntered(")) |idx| {
            count += 1;
            search_start = idx + 1;
        }
        try expect.equal(count, @as(usize, 3));

        // And each id appears exactly once, paired with the right
        // flow_name argument.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 10) catch {};") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 20) catch {};") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 30) catch {};") != null);
    }

    test "round-trips the issue #46 example" {
        const allocator = std.testing.allocator;
        // Identical to FlowIoTests.sample_issue_46. The codegen
        // pipeline interprets `GetComponent -> BinOp.a` via the
        // producer pin name `"x"` as a field access on the bound
        // component (`n1_value.x`).
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{280, 80}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 3, .pos = .{440, 80}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 3, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "move");
        defer allocator.free(out);

        // The expected statements, in order. We assert ordering by
        // checking that each appears AFTER the previous one in the
        // output. Position-sensitive -- catches any future regression
        // where a node ends up upstream of its dependencies.
        const expected_in_order = [_][]const u8{
            "const n1_value = game.getComponent(entity, Position) orelse return;",
            "const n2_result = n1_value.x + 0;",
            "game.setField(Position, .x, entity, n2_result);",
        };
        var prev: usize = 0;
        for (expected_in_order) |needle| {
            const at = std.mem.indexOfPos(u8, out, prev, needle) orelse {
                std.debug.print("missing in output: '{s}'\noutput was:\n{s}\n", .{ needle, out });
                return error.TestExpectedSubstring;
            };
            prev = at + needle.len;
        }

        // OnUpdate flows that touch entities get the TODO stub so
        // the file still parses.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity: EntityId = undefined;") != null);
    }

    test "GetComponent node emits component @import in prelude" {
        // Issue #101: the codegen used to reference `Position` without
        // importing it, so the emitted file failed to compile.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_gc");
        defer allocator.free(out);

        const needle = "const Position = @import(\"../../components/Position.zig\").Position;";
        try expect.toBeTrue(std.mem.indexOf(u8, out, needle) != null);
        // Exactly once -- no duplicate emission.
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, out, start, needle)) |at| {
            count += 1;
            start = at + 1;
        }
        try expect.equal(count, @as(usize, 1));

        // And it lands in the prelude, before the function header.
        const import_at = std.mem.indexOf(u8, out, needle).?;
        const fn_at = std.mem.indexOf(u8, out, "pub fn onCreate").?;
        try expect.toBeTrue(import_at < fn_at);
    }

    test "SetField target extracts type-name with the same split rule as the template" {
        // The SetField template uses `lastIndexOfScalar('.')` to peel
        // the type off `target`. The import collector must use the
        // same split so a target like `Position.x` produces a single
        // `Position` import that matches the symbol the template
        // actually references.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "42" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_sf");
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const Position = @import(\"../../components/Position.zig\").Position;") != null);
        // And the SetField template still calls into the same name.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n1_value);") != null);
    }

    test "duplicate component references emit exactly one @import" {
        // Two GetComponent nodes for the same type used to risk
        // emitting two import lines. The collector de-dupes via a
        // string set.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "0" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 4, .pin = "value" }, .to = .{ .node = 3, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_dup");
        defer allocator.free(out);

        const needle = "const Position = @import(\"../../components/Position.zig\").Position;";
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, out, start, needle)) |at| {
            count += 1;
            start = at + 1;
        }
        try expect.equal(count, @as(usize, 1));
    }

    test "multiple distinct component types emit sorted @import lines" {
        // Alphabetical order keeps the output byte-stable across
        // graph re-arrangements -- a `Velocity` node added before a
        // `Position` node would otherwise flip the prelude.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Velocity" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_sort");
        defer allocator.free(out);

        const pos_needle = "const Position = @import(\"../../components/Position.zig\").Position;";
        const vel_needle = "const Velocity = @import(\"../../components/Velocity.zig\").Velocity;";
        const pos_at = std.mem.indexOf(u8, out, pos_needle) orelse return error.TestExpectedSubstring;
        const vel_at = std.mem.indexOf(u8, out, vel_needle) orelse return error.TestExpectedSubstring;
        try expect.toBeTrue(pos_at < vel_at);
    }

    test "namespaced component type name surfaces NamespacedComponentType error" {
        // Bare identifiers only in v1: `const foo.bar.Baz = @import(...);`
        // isn't valid Zig, so the codegen must refuse rather than emit
        // a broken prelude. Tracked for v2.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "foo.bar.Baz" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const result = renderFromZon(allocator, src, "ns");
        try expect.toBeTrue(if (result) |out| blk: {
            allocator.free(out);
            break :blk false;
        } else |err| err == error.NamespacedComponentType);
    }

    test "SetField target with multi-dot type name surfaces NamespacedComponentType" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "foo.bar.Baz.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const result = renderFromZon(allocator, src, "ns_sf");
        try expect.toBeTrue(if (result) |out| blk: {
            allocator.free(out);
            break :blk false;
        } else |err| err == error.NamespacedComponentType);
    }

    test "flow with no component references emits zero component @imports" {
        // Don't leak imports into pure-arithmetic flows -- they'd
        // reference files that don't exist on disk.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 3, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "b" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_none");
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "@import(\"../../components/") == null);
    }

    test "output passes std.zig.Ast.parse without errors" {
        // The single strongest correctness signal -- anything we
        // emit must be syntactically valid Zig.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{280, 80}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 3, .pos = .{440, 80}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\        .{ .id = 5, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 6, .pos = .{0, 0}, .kind = .{ .Call = .{ .callee = "std.math.max" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 4, .pin = "value" }, .to = .{ .node = 2, .pin = "b" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 6, .pin = "arg0" } },
            \\        .{ .from = .{ .node = 5, .pin = "value" }, .to = .{ .node = 6, .pin = "arg1" } },
            \\        .{ .from = .{ .node = 6, .pin = "result" }, .to = .{ .node = 3, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "all_kinds");
        defer allocator.free(out);

        // `std.zig.Ast.parse` needs a sentinel-terminated source.
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);

        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) {
            std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        }
        try expect.equal(ast.errors.len, @as(usize, 0));
    }
};
