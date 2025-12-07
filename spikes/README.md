# Plugin System Spikes

This folder contains proof-of-concept implementations for different plugin/extension system architectures for Labelle GUI.

## Spikes Overview

### 01-compile-time-modules

**Status:** Working

A compile-time module system where plugins are registered at build time.

```bash
cd 01-compile-time-modules && zig build run
```

**Pros:**
- Type-safe at compile time
- No runtime overhead
- Simple to implement
- Full access to Zig's type system

**Cons:**
- Requires recompilation to add/remove modules
- All modules must be known at build time
- Not suitable for user-created plugins

**Best for:** Core application features, built-in tools

### 02-dynamic-loading

**Status:** Working

Dynamic library loading using Zig's `std.DynLib` for runtime plugin loading.

```bash
cd 02-dynamic-loading && zig build run
```

**Pros:**
- Plugins can be added/removed without recompiling host
- Users can create and distribute plugins
- Hot-reloading possible

**Cons:**
- ABI stability concerns between versions
- Platform-specific (.so, .dll, .dylib)
- More complex error handling
- Potential security concerns with arbitrary code

**Best for:** Power user plugins, third-party extensions

### 03-lua-scripting

**Status:** Working (Mock implementation)

Lua scripting integration for user scripts. Currently uses a mock implementation to demonstrate the architecture.

```bash
cd 03-lua-scripting && zig build run
```

**Pros:**
- Safe sandboxed execution
- Easy for non-programmers to write
- Hot-reloading is trivial
- Cross-platform scripts
- No compilation needed

**Cons:**
- Performance overhead for script calls
- Limited access to system resources (by design)
- Requires embedding Lua runtime

**Best for:** User macros, simple automation, theming

## Recommendations

### Hybrid Approach

For Labelle GUI, a hybrid approach is recommended:

1. **Core Features:** Use compile-time modules (spike 01) for built-in panels like Scene Hierarchy, Properties, Asset Browser, etc.

2. **Advanced Plugins:** Support dynamic loading (spike 02) for power users who want to create compiled plugins with full access.

3. **User Scripts:** Use Lua scripting (spike 03) for simple automation, custom tools, and safe user scripting.

### Implementation Priority

1. Start with compile-time modules for core features
2. Add Lua scripting for user customization
3. Consider dynamic loading for advanced use cases later

### Real Lua Integration

For actual Lua integration, use [ziglua](https://github.com/natecraddock/ziglua):

```zig
// build.zig.zon
.dependencies = .{
    .ziglua = .{
        .url = "https://github.com/natecraddock/ziglua/archive/refs/heads/main.tar.gz",
        // Add hash after first build attempt
    },
},
```

## Running All Spikes

```bash
# From spikes/ directory
for spike in 01-* 02-* 03-*; do
    echo "=== Running $spike ==="
    (cd "$spike" && zig build run)
    echo
done
```
