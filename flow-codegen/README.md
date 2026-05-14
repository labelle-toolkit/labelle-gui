# flow_codegen

Pure-Zig parser and codegen for `.flow.zon` files. Sub-package of
`labelle-gui`, mirroring `labelle-engine`'s `audio_backend` and
`labelle-gfx`'s `spatial_grid` sub-packages.

Two modules live here:

- `flow_io` — read/write the `.flow.zon` on-disk schema (issue #46).
- `codegen` — turn a parsed `Flow` into a `.zig` source file
  (issue #50). Topo-sorts the graph, emits a preview pulse preamble
  per node, and renders per-kind templates.

Consumed by `labelle-gui` (the editor that authors flow files) and
`labelle-assembler` (which generates Zig code at `zig build generate`
time). The split exists so `labelle-assembler` can depend on the
pure-Zig pieces without pulling in the gui's imgui/zgui stack.

The gui-side projector / renderers / types modules stay in
`labelle-gui/src/flows/` — they consume `std.zig.Ast` for the
Zig-to-graph projector and have nothing to do with the on-disk schema.

Consumers pick this up via a path dep on `labelle-gui`:

```zig
// in a consumer's build.zig.zon
.dependencies = .{
    .labelle_gui = .{ .path = "../labelle-gui" },
},
```

```zig
// in build.zig
const gui_dep = b.dependency("labelle_gui", ...);
const flow_codegen = gui_dep.module("flow_codegen");
```

Tracking issue: [labelle-gui#94](https://github.com/labelle-toolkit/labelle-gui/issues/94).
