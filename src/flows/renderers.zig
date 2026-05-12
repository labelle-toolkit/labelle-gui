//! Per-AST-tag renderers for the Flows projector (issue #48).
//!
//! Each renderer takes the projector context + the AST node being
//! visited, allocates a `GraphNodeSpec` off the projector's arena,
//! pushes it through `Projector.emitNode`, and optionally walks
//! children to attach edges.
//!
//! `dispatch(p, node, parent_id)` is the entry point — the projector
//! calls it for every statement and recursively for every operand
//! it wants to materialize as its own node. Tags not explicitly
//! covered fall through to the generic expression renderer which
//! captures the raw source slice.
//!
//! Phase 1 — no component-aware renderings yet (engine-side
//! ComponentRegistry integration is its own scope; #48 lists Position
//! + Sprite as the second-step target). The framework is here: the
//! call renderer slots in component-aware specializations by call
//! target name when those land.

const std = @import("std");
const Ast = std.zig.Ast;

const types = @import("types.zig");
const Projector = @import("projector.zig").Projector;

const GraphNodeSpec = types.GraphNodeSpec;
const PinSpec = types.PinSpec;
const EdgeSpec = types.EdgeSpec;

/// Dispatch one AST node to its renderer. Returns the emitted node's
/// id (so callers can wire edges from it to a parent), or null when
/// the node didn't produce a graph node (e.g. a trivial literal).
pub fn dispatch(p: *Projector, node: Ast.Node.Index, parent_id: u32) anyerror!?u32 {
    const tag = p.ast.nodeTag(node);

    return switch (tag) {
        .call_one, .call_one_comma, .call, .call_comma => try renderCall(p, node, parent_id),

        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .bool_and,
        .bool_or,
        => try renderBinop(p, node, parent_id),

        .negation,
        .bool_not,
        .bit_not,
        .address_of,
        => try renderUnop(p, node, parent_id),

        .if_simple, .@"if" => try renderBranch(p, node, parent_id),

        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        => try renderLoop(p, node, parent_id),

        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => try renderVarDecl(p, node, parent_id),

        .identifier => try renderIdentifier(p, node, parent_id),

        .field_access => try renderFieldAccess(p, node, parent_id),

        .struct_init,
        .struct_init_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        => try renderStructInit(p, node, parent_id),

        .@"return" => try renderReturn(p, node, parent_id),

        else => try renderGeneric(p, node, parent_id),
    };
}

// ─── Function entry-point (root node for a fn) ─────────────────────

/// Render an entry-point function as a graph root. Called by the
/// projector once per entry-point fn before walking its body. The
/// returned id is the body's `parent_id`.
pub fn renderFunctionEntry(p: *Projector, decl: Ast.Node.Index) !u32 {
    const ast = p.ast;
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, decl) orelse return error.NotAFunction;

    const name = if (proto.name_token) |tok| ast.tokenSlice(tok) else "<anon>";
    const label = try std.fmt.allocPrint(p.arena, "fn {s}", .{name});

    // One output exec pin so the body's first statement can hang off
    // it. Params land as input pins so the user sees the function's
    // surface area at a glance.
    var params: std.ArrayList(PinSpec) = .{};
    defer params.deinit(p.arena);

    var it = proto.iterate(ast);
    while (it.next()) |param| {
        const pname_tok = param.name_token orelse continue;
        const pname = ast.tokenSlice(pname_tok);
        const type_text = if (param.type_expr) |t|
            try p.arena.dupe(u8, ast.getNodeSource(t))
        else if (param.anytype_ellipsis3 != null)
            try p.arena.dupe(u8, "anytype")
        else
            try p.arena.dupe(u8, "?unknown");

        const pin: PinSpec = .{
            .id = p.newPinId(),
            .name = try p.arena.dupe(u8, pname),
            .type_name = type_text,
        };
        try params.append(p.arena, pin);
    }

    const node_id = p.newNodeId();
    const exec_pin: PinSpec = .{
        .id = p.newPinId(),
        .name = try p.arena.dupe(u8, "body"),
        .type_name = try p.arena.dupe(u8, "exec"),
    };

    const inputs = try p.arena.dupe(PinSpec, params.items);
    const outputs = try p.arena.alloc(PinSpec, 1);
    outputs[0] = exec_pin;

    try p.emitNode(.{
        .id = node_id,
        .label = label,
        .source_line = p.sourceLineOf(decl),
        .category = .entry_point,
        .input_pins = inputs,
        .output_pins = outputs,
    });

    // Each named param is a fresh in-scope value the body can refer
    // back to. Bind by name so `identifier` renderers can hook back.
    for (inputs) |pin| {
        try p.bindVar(pin.name, .{ .node = node_id, .pin = pin.id });
    }
    return node_id;
}

// ─── Function call ─────────────────────────────────────────────────

fn renderCall(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    var buf: [1]Ast.Node.Index = undefined;
    const call = ast.fullCall(&buf, node) orelse return null;

    // The call target's source text is the label. `getNodeSource`
    // gives the raw slice which is correct for both `foo` and
    // `engine.SpriteAnimation.config` style chains.
    const callee = try p.arena.dupe(u8, ast.getNodeSource(call.ast.fn_expr));

    var input_pins: std.ArrayList(PinSpec) = .{};
    defer input_pins.deinit(p.arena);
    for (call.ast.params, 0..) |_, i| {
        const name = try std.fmt.allocPrint(p.arena, "arg{d}", .{i});
        try input_pins.append(p.arena, .{
            .id = p.newPinId(),
            .name = name,
            .type_name = try p.arena.dupe(u8, "?unknown"),
        });
    }

    const result_pin: PinSpec = .{
        .id = p.newPinId(),
        .name = try p.arena.dupe(u8, "result"),
        .type_name = try p.arena.dupe(u8, "?unknown"),
    };

    const id = p.newNodeId();
    try p.emitNode(.{
        .id = id,
        .label = callee,
        .source_line = p.sourceLineOf(node),
        .category = .call,
        .input_pins = try p.arena.dupe(PinSpec, input_pins.items),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{result_pin}),
    });

    // Wire each argument's emitted child node (if any) to the call's
    // matching input pin.
    for (call.ast.params, 0..) |arg, i| {
        if (try dispatch(p, arg, id)) |child_id| {
            try p.emitEdge(.{
                .from_node = child_id,
                .from_pin = lastOutputPinOf(p, child_id),
                .to_node = id,
                .to_pin = input_pins.items[i].id,
                .kind = .data,
            });
        }
    }
    _ = parent_id;
    return id;
}

// ─── Binary op ─────────────────────────────────────────────────────

fn renderBinop(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const data = ast.nodeData(node).node_and_node;
    const lhs = data[0];
    const rhs = data[1];

    const op_label = try p.arena.dupe(u8, ast.tokenSlice(ast.nodeMainToken(node)));
    const id = p.newNodeId();
    const in_l: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "lhs"), .type_name = try p.arena.dupe(u8, "?unknown") };
    const in_r: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "rhs"), .type_name = try p.arena.dupe(u8, "?unknown") };
    const out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "out"), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = op_label,
        .source_line = p.sourceLineOf(node),
        .category = .binop,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{ in_l, in_r }),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{out}),
    });

    if (try dispatch(p, lhs, id)) |lhs_id| {
        try p.emitEdge(.{
            .from_node = lhs_id,
            .from_pin = lastOutputPinOf(p, lhs_id),
            .to_node = id,
            .to_pin = in_l.id,
            .kind = .data,
        });
    }
    if (try dispatch(p, rhs, id)) |rhs_id| {
        try p.emitEdge(.{
            .from_node = rhs_id,
            .from_pin = lastOutputPinOf(p, rhs_id),
            .to_node = id,
            .to_pin = in_r.id,
            .kind = .data,
        });
    }
    _ = parent_id;
    return id;
}

// ─── Unary op ──────────────────────────────────────────────────────

fn renderUnop(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const operand = ast.nodeData(node).node;

    const op_label = try p.arena.dupe(u8, ast.tokenSlice(ast.nodeMainToken(node)));
    const id = p.newNodeId();
    const in: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "in"), .type_name = try p.arena.dupe(u8, "?unknown") };
    const out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "out"), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = op_label,
        .source_line = p.sourceLineOf(node),
        .category = .unop,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{in}),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{out}),
    });

    if (try dispatch(p, operand, id)) |child_id| {
        try p.emitEdge(.{
            .from_node = child_id,
            .from_pin = lastOutputPinOf(p, child_id),
            .to_node = id,
            .to_pin = in.id,
            .kind = .data,
        });
    }
    _ = parent_id;
    return id;
}

// ─── if / else (branch) ────────────────────────────────────────────

fn renderBranch(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const branch = ast.fullIf(node) orelse return null;

    const id = p.newNodeId();
    const cond_in: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "cond"), .type_name = try p.arena.dupe(u8, "bool") };
    const then_out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "then"), .type_name = try p.arena.dupe(u8, "exec") };
    const else_out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "else"), .type_name = try p.arena.dupe(u8, "exec") };

    try p.emitNode(.{
        .id = id,
        .label = try p.arena.dupe(u8, "if"),
        .source_line = p.sourceLineOf(node),
        .category = .branch,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{cond_in}),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{ then_out, else_out }),
    });

    if (try dispatch(p, branch.ast.cond_expr, id)) |cond_id| {
        try p.emitEdge(.{
            .from_node = cond_id,
            .from_pin = lastOutputPinOf(p, cond_id),
            .to_node = id,
            .to_pin = cond_in.id,
            .kind = .data,
        });
    }
    if (try dispatch(p, branch.ast.then_expr, id)) |then_id| {
        try p.emitEdge(.{
            .from_node = id,
            .from_pin = then_out.id,
            .to_node = then_id,
            .to_pin = firstInputPinOrSynthetic(p, then_id),
            .kind = .execution,
        });
    }
    if (branch.ast.else_expr.unwrap()) |else_expr| {
        if (try dispatch(p, else_expr, id)) |else_id| {
            try p.emitEdge(.{
                .from_node = id,
                .from_pin = else_out.id,
                .to_node = else_id,
                .to_pin = firstInputPinOrSynthetic(p, else_id),
                .kind = .execution,
            });
        }
    }
    _ = parent_id;
    return id;
}

// ─── while / for ───────────────────────────────────────────────────

fn renderLoop(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const tag = ast.nodeTag(node);

    const id = p.newNodeId();
    const cond_in: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "cond"), .type_name = try p.arena.dupe(u8, "bool") };
    const body_out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "body"), .type_name = try p.arena.dupe(u8, "exec") };

    const label_text = switch (tag) {
        .while_simple, .while_cont, .@"while" => "while",
        .for_simple, .@"for" => "for",
        else => "loop",
    };
    try p.emitNode(.{
        .id = id,
        .label = try p.arena.dupe(u8, label_text),
        .source_line = p.sourceLineOf(node),
        .category = .loop,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{cond_in}),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{body_out}),
    });

    // Pull the condition + body out depending on the loop flavour.
    // `for` and `while` share enough shape that fullWhile/fullFor
    // give us a uniform components view.
    var cond_node: ?Ast.Node.Index = null;
    var body_node: ?Ast.Node.Index = null;
    if (ast.fullWhile(node)) |w| {
        cond_node = w.ast.cond_expr;
        body_node = w.ast.then_expr;
    } else if (ast.fullFor(node)) |f| {
        // `for` has no single condition expr — the input is the
        // iterable. Use the first input as the "cond" pin payload.
        if (f.ast.inputs.len > 0) cond_node = f.ast.inputs[0];
        body_node = f.ast.then_expr;
    }

    if (cond_node) |c| {
        if (try dispatch(p, c, id)) |c_id| {
            try p.emitEdge(.{
                .from_node = c_id,
                .from_pin = lastOutputPinOf(p, c_id),
                .to_node = id,
                .to_pin = cond_in.id,
                .kind = .data,
            });
        }
    }
    if (body_node) |b| {
        if (try dispatch(p, b, id)) |b_id| {
            try p.emitEdge(.{
                .from_node = id,
                .from_pin = body_out.id,
                .to_node = b_id,
                .to_pin = firstInputPinOrSynthetic(p, b_id),
                .kind = .execution,
            });
        }
    }
    _ = parent_id;
    return id;
}

// ─── Variable declaration ──────────────────────────────────────────

fn renderVarDecl(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const decl = ast.fullVarDecl(node) orelse return null;
    // Name token sits immediately after the `var`/`const` keyword.
    const name = ast.tokenSlice(decl.ast.mut_token + 1);

    const id = p.newNodeId();
    const init_in: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "init"), .type_name = try p.arena.dupe(u8, "?unknown") };
    const value_out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, name), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = try std.fmt.allocPrint(p.arena, "var {s}", .{name}),
        .source_line = p.sourceLineOf(node),
        .category = .var_decl,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{init_in}),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{value_out}),
    });

    if (decl.ast.init_node.unwrap()) |init_expr| {
        if (try dispatch(p, init_expr, id)) |init_id| {
            try p.emitEdge(.{
                .from_node = init_id,
                .from_pin = lastOutputPinOf(p, init_id),
                .to_node = id,
                .to_pin = init_in.id,
                .kind = .data,
            });
        }
    }

    // Make this binding visible to later identifier references.
    try p.bindVar(name, .{ .node = id, .pin = value_out.id });
    _ = parent_id;
    return id;
}

// ─── Identifier reference ──────────────────────────────────────────

fn renderIdentifier(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const name = ast.tokenSlice(ast.nodeMainToken(node));

    // If we've seen this name bound earlier in scope, emit a
    // reference node that wires back to the producing pin. Otherwise
    // (param, module-level decl) we still surface an identifier node
    // so the caller has something to connect to.
    const id = p.newNodeId();
    const out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, name), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = try p.arena.dupe(u8, name),
        .source_line = p.sourceLineOf(node),
        .category = .identifier,
        .input_pins = try p.arena.alloc(PinSpec, 0),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{out}),
    });

    if (p.lookupVar(name)) |binding| {
        try p.emitEdge(.{
            .from_node = binding.node,
            .from_pin = binding.pin,
            .to_node = id,
            .to_pin = out.id, // synthetic input: identifier nodes have no real inputs
            .kind = .data,
        });
    }
    _ = parent_id;
    return id;
}

// ─── Field access ──────────────────────────────────────────────────

fn renderFieldAccess(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const data = ast.nodeData(node).node_and_token;
    const lhs = data[0];
    const field_tok = data[1];
    const field_name = ast.tokenSlice(field_tok);

    const id = p.newNodeId();
    const struct_in: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "struct"), .type_name = try p.arena.dupe(u8, "?unknown") };
    const field_out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, field_name), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = try std.fmt.allocPrint(p.arena, ".{s}", .{field_name}),
        .source_line = p.sourceLineOf(node),
        .category = .field_access,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{struct_in}),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{field_out}),
    });

    if (try dispatch(p, lhs, id)) |lhs_id| {
        try p.emitEdge(.{
            .from_node = lhs_id,
            .from_pin = lastOutputPinOf(p, lhs_id),
            .to_node = id,
            .to_pin = struct_in.id,
            .kind = .data,
        });
    }
    _ = parent_id;
    return id;
}

// ─── Struct literal ────────────────────────────────────────────────

fn renderStructInit(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    var buf: [2]Ast.Node.Index = undefined;
    const init_full = ast.fullStructInit(&buf, node) orelse return null;

    var input_pins: std.ArrayList(PinSpec) = .{};
    defer input_pins.deinit(p.arena);
    for (init_full.ast.fields, 0..) |_, i| {
        const name = try std.fmt.allocPrint(p.arena, "f{d}", .{i});
        try input_pins.append(p.arena, .{
            .id = p.newPinId(),
            .name = name,
            .type_name = try p.arena.dupe(u8, "?unknown"),
        });
    }

    const out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "value"), .type_name = try p.arena.dupe(u8, "struct") };

    const id = p.newNodeId();
    try p.emitNode(.{
        .id = id,
        .label = try p.arena.dupe(u8, "struct{...}"),
        .source_line = p.sourceLineOf(node),
        .category = .struct_init,
        .input_pins = try p.arena.dupe(PinSpec, input_pins.items),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{out}),
    });

    for (init_full.ast.fields, 0..) |field, i| {
        if (try dispatch(p, field, id)) |child_id| {
            try p.emitEdge(.{
                .from_node = child_id,
                .from_pin = lastOutputPinOf(p, child_id),
                .to_node = id,
                .to_pin = input_pins.items[i].id,
                .kind = .data,
            });
        }
    }
    _ = parent_id;
    return id;
}

// ─── Return ────────────────────────────────────────────────────────

fn renderReturn(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    const opt = ast.nodeData(node).opt_node;

    const id = p.newNodeId();
    const in: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "value"), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = try p.arena.dupe(u8, "return"),
        .source_line = p.sourceLineOf(node),
        .category = .terminator,
        .input_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{in}),
        .output_pins = try p.arena.alloc(PinSpec, 0),
    });

    if (opt.unwrap()) |val_node| {
        if (try dispatch(p, val_node, id)) |v_id| {
            try p.emitEdge(.{
                .from_node = v_id,
                .from_pin = lastOutputPinOf(p, v_id),
                .to_node = id,
                .to_pin = in.id,
                .kind = .data,
            });
        }
    }
    _ = parent_id;
    return id;
}

// ─── Generic fallback ──────────────────────────────────────────────

fn renderGeneric(p: *Projector, node: Ast.Node.Index, parent_id: u32) !?u32 {
    const ast = p.ast;
    // Cap the snippet so a wild expression doesn't blow out the node
    // header. Real inspection happens in the sidebar.
    const raw = ast.getNodeSource(node);
    const label = try p.arena.dupe(u8, if (raw.len > 40) raw[0..40] else raw);

    const id = p.newNodeId();
    const out: PinSpec = .{ .id = p.newPinId(), .name = try p.arena.dupe(u8, "out"), .type_name = try p.arena.dupe(u8, "?unknown") };

    try p.emitNode(.{
        .id = id,
        .label = label,
        .source_line = p.sourceLineOf(node),
        .category = .generic,
        .input_pins = try p.arena.alloc(PinSpec, 0),
        .output_pins = try p.arena.dupe(PinSpec, &[_]PinSpec{out}),
    });
    _ = parent_id;
    return id;
}

// ─── Pin helpers ───────────────────────────────────────────────────

/// Return the last output pin id of `node_id`, or a synthetic value
/// when the node has no outputs (terminator-style nodes). Edge
/// targets need *something* so the node-editor can draw a line; we
/// reuse the node's own id as the pin id in that case, since
/// node-editor never sees the synthetic edge as a real connection.
fn lastOutputPinOf(p: *const Projector, node_id: u32) u32 {
    for (p.nodes.items) |n| {
        if (n.id == node_id) {
            if (n.output_pins.len == 0) return node_id;
            return n.output_pins[n.output_pins.len - 1].id;
        }
    }
    return node_id;
}

fn firstInputPinOrSynthetic(p: *const Projector, node_id: u32) u32 {
    for (p.nodes.items) |n| {
        if (n.id == node_id) {
            if (n.input_pins.len == 0) return node_id;
            return n.input_pins[0].id;
        }
    }
    return node_id;
}
