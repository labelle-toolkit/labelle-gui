//! Reverse navigation for the Flows viewer (issue #42, Phase 4).
//!
//! Closes the loop the issue describes: see a node in the derived
//! graph → jump to the exact line of the Zig source the LLM (or a
//! human) wrote. The Zig file is the source of truth; this module is
//! the "take me there" affordance.
//!
//! There is no built-in source editor in labelle-gui, so "jump to
//! source" means handing the file (and, where possible, a line
//! number) to the user's external editor. Two strategies, tried in
//! order:
//!
//!   1. `$LABELLE_FLOW_EDITOR`, then `$VISUAL`, then `$EDITOR`. When
//!      the editor command's basename is one we recognise, we splice
//!      in that editor's line-jump syntax so the cursor lands on the
//!      construct, not just the top of the file. A `program flag`
//!      command line (`code --wait`) is split on whitespace; a spaced
//!      program *path* that resolves to a real file is used verbatim
//!      (see `forEachEditorWord`).
//!   2. The OS-native file handler (`open` / `xdg-open` / `cmd /c
//!      start`). No line number — the handler routes the file to
//!      whatever app owns `.zig`, and most of those can't be told a
//!      line from the command line.
//!
//! `reveal` spawns the launcher on the calling (UI) thread — `spawn`
//! returns the instant the child is forked/exec'd, so the gui never
//! stalls there, and a spawn failure surfaces synchronously to the
//! caller. Reaping the child (the blocking `wait`) is then handed to a
//! short-lived detached background thread: a terminal editor or a
//! `code --wait`-style `$EDITOR` can keep the launcher alive for the
//! whole editing session, and we must not freeze the gui waiting on
//! it. `reveal` is best-effort — a failure to launch is reported to
//! the caller, not retried.

const std = @import("std");
const builtin = @import("builtin");

const io_global = @import("../io_global.zig");

/// Editors whose command line accepts a "go to this line" form. The
/// `kind` drives how `composeEditorArgv` splices the line number in.
const KnownEditor = struct {
    /// Lowercased basename to match against (no extension on Windows —
    /// we strip `.exe` / `.cmd` before comparing).
    name: []const u8,
    kind: Kind,

    const Kind = enum {
        /// `editor --goto file:line` — VS Code and friends.
        vscode_goto,
        /// `editor +line file` — vim, nvim, emacs, nano, gedit, kate.
        plus_line,
        /// `editor --line line file` — sublime-style.
        dash_dash_line,
    };
};

const known_editors = [_]KnownEditor{
    .{ .name = "code", .kind = .vscode_goto },
    .{ .name = "code-insiders", .kind = .vscode_goto },
    .{ .name = "codium", .kind = .vscode_goto },
    .{ .name = "cursor", .kind = .vscode_goto },
    .{ .name = "zed", .kind = .vscode_goto },
    .{ .name = "vim", .kind = .plus_line },
    .{ .name = "nvim", .kind = .plus_line },
    .{ .name = "gvim", .kind = .plus_line },
    .{ .name = "emacs", .kind = .plus_line },
    .{ .name = "nano", .kind = .plus_line },
    .{ .name = "gedit", .kind = .plus_line },
    .{ .name = "kate", .kind = .plus_line },
    .{ .name = "subl", .kind = .dash_dash_line },
    .{ .name = "sublime_text", .kind = .dash_dash_line },
};

/// Result of resolving a reveal request into an argv. `Plan` borrows
/// every string it carries — `file` from the caller, env-derived
/// strings from `env`, and the formatted `file:line` (when used) from
/// `scratch`. Nothing here is owned; it stays valid only as long as
/// the `argv_buf` / `scratch` / `editor` passed to `planReveal` do, so
/// it must be spawned from before any of those drop. It never escapes
/// `reveal` — `reveal` returns the value-only `RevealResult` instead.
pub const Plan = struct {
    /// The argv to spawn. Always at least one element.
    argv: []const []const u8,
    /// True when `argv` carries a line number — i.e. the cursor will
    /// land on `line`, not just the file's top. UI can surface this
    /// (e.g. "Open in editor" vs "Open file").
    has_line: bool,
};

/// What `reveal` reports back to the caller. A plain value — it owns
/// nothing and borrows nothing, so it is safe to return and outlive
/// the call (unlike `Plan`, whose slices point into `reveal`'s stack).
pub const RevealResult = struct {
    /// True when the spawned command carried a line number, so the
    /// editor's cursor lands on `line` rather than the file's top.
    has_line: bool,
};

/// Does `path` name a file that exists on disk? Used to tell a spaced
/// *program path* (`C:\Program Files\Microsoft VS Code\Code.exe`) from
/// a `program flag` command line (`code --wait`): if the whole string
/// resolves to a real file we treat it verbatim, otherwise we split on
/// whitespace. `path` must look like a path (contain a separator) —
/// a bare name like `code` is found on `$PATH`, not the cwd, so we
/// never probe those and let tokenization handle them.
fn isExistingExecutable(path: []const u8) bool {
    if (std.fs.path.dirname(path) == null) return false;
    const io = io_global.io();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Split an editor command into argv words. The common case is a
/// shell-style `program flag…` string (`"code --wait"`) which we
/// tokenize on whitespace. The exception is a program *path* that
/// itself contains spaces (`C:\Program Files\…\Code.exe`): tokenizing
/// that would shred the path into bogus args. So we first probe the
/// whole, untrimmed string — if it resolves to a real file, it is one
/// argv word verbatim; only when it does not do we fall back to
/// whitespace splitting. `$LABELLE_FLOW_EDITOR` overrides `$EDITOR`
/// for users who still want full control.
///
/// Calls `f` once per word, in order. Returns false (calling `f` for
/// nothing) only when `cmd` is empty/all-whitespace.
fn forEachEditorWord(cmd: []const u8, f: anytype) bool {
    const trimmed = std.mem.trim(u8, cmd, " \t");
    if (trimmed.len == 0) return false;
    if (isExistingExecutable(trimmed)) {
        // Whole value is a real executable — a spaced program path.
        // Use it verbatim as a single argv word, no splitting.
        f.add(trimmed);
        return true;
    }
    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
    var any = false;
    while (tok.next()) |word| {
        f.add(word);
        any = true;
    }
    return any;
}

/// Lowercased basename of a command, with a trailing `.exe` / `.cmd`
/// / `.bat` stripped (Windows). `$EDITOR` is often an absolute path
/// or carries flags; we only ever match on the program name.
///
/// The program word is taken via `forEachEditorWord`, so a spaced
/// executable *path* (resolving to a real file) is honoured as one
/// word — only `program flag` command lines are split on whitespace.
fn programBasename(cmd: []const u8) []const u8 {
    var picker = struct {
        first: ?[]const u8 = null,
        fn add(self: *@This(), word: []const u8) void {
            if (self.first == null) self.first = word;
        }
    }{};
    _ = forEachEditorWord(cmd, &picker);
    const first = picker.first orelse cmd;
    const base = std.fs.path.basename(first);
    inline for (.{ ".exe", ".cmd", ".bat" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(base, suffix)) {
            return base[0 .. base.len - suffix.len];
        }
    }
    return base;
}

/// Match `cmd`'s program name against `known_editors`. Returns null
/// when the editor isn't one whose line-jump syntax we know — the
/// caller then opens the file without a line.
fn classifyEditor(cmd: []const u8) ?KnownEditor.Kind {
    const base = programBasename(cmd);
    for (known_editors) |ed| {
        if (std.ascii.eqlIgnoreCase(base, ed.name)) return ed.kind;
    }
    return null;
}

/// Build the argv for a known editor. Writes the formatted
/// `file:line` (vscode kind only) into `scratch`. `argv_buf` receives
/// the argv slices; the returned slice points into it.
///
/// `editor` is the raw command — it may include flags (`code --wait`).
/// `forEachEditorWord` turns it into leading argv slots: a spaced
/// program *path* that resolves to a real file stays one word, while
/// a `program flag` command line is split on whitespace.
fn composeEditorArgv(
    argv_buf: [][]const u8,
    scratch: []u8,
    editor: []const u8,
    kind: KnownEditor.Kind,
    file: []const u8,
    line: u32,
) ?[]const []const u8 {
    // Editor command + any embedded flags become leading argv slots.
    var sink = struct {
        buf: [][]const u8,
        n: usize = 0,
        overflow: bool = false,
        fn add(self: *@This(), word: []const u8) void {
            if (self.n >= self.buf.len) {
                self.overflow = true;
                return;
            }
            self.buf[self.n] = word;
            self.n += 1;
        }
    }{ .buf = argv_buf };
    _ = forEachEditorWord(editor, &sink);
    if (sink.overflow) return null;
    var n: usize = sink.n;
    if (n == 0) return null;

    switch (kind) {
        .vscode_goto => {
            // `code --goto file:line` — one combined `file:line` arg.
            if (n + 2 > argv_buf.len) return null;
            const goto = std.fmt.bufPrint(scratch, "{s}:{d}", .{ file, line }) catch return null;
            argv_buf[n] = "--goto";
            argv_buf[n + 1] = goto;
            n += 2;
        },
        .plus_line => {
            // `vim +line file` — the `+N` token must precede the file.
            if (n + 2 > argv_buf.len) return null;
            const plus = std.fmt.bufPrint(scratch, "+{d}", .{line}) catch return null;
            argv_buf[n] = plus;
            argv_buf[n + 1] = file;
            n += 2;
        },
        .dash_dash_line => {
            // `subl --line N file`.
            if (n + 3 > argv_buf.len) return null;
            const num = std.fmt.bufPrint(scratch, "{d}", .{line}) catch return null;
            argv_buf[n] = "--line";
            argv_buf[n + 1] = num;
            argv_buf[n + 2] = file;
            n += 3;
        },
    }
    return argv_buf[0..n];
}

/// The OS-native file-open command for the current target. No line
/// number — the OS handler routes by extension and most `.zig`
/// handlers ignore extra args.
fn osOpenArgv(argv_buf: [][]const u8, file: []const u8) []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => blk: {
            argv_buf[0] = "open";
            argv_buf[1] = file;
            break :blk argv_buf[0..2];
        },
        .windows => blk: {
            // `cmd /c start "" file` — the empty `""` is `start`'s
            // window-title arg; without it `start` treats a quoted
            // path as the title.
            argv_buf[0] = "cmd";
            argv_buf[1] = "/c";
            argv_buf[2] = "start";
            argv_buf[3] = "";
            argv_buf[4] = file;
            break :blk argv_buf[0..5];
        },
        else => blk: {
            // Linux / *BSD — freedesktop `xdg-open`.
            argv_buf[0] = "xdg-open";
            argv_buf[1] = file;
            break :blk argv_buf[0..2];
        },
    };
}

/// Resolve a reveal request into a spawnable `Plan`.
///
/// `editor_env` is the editor command from the environment (the
/// caller looks up `$LABELLE_FLOW_EDITOR` / `$VISUAL` / `$EDITOR` and
/// passes the first non-empty one, or null). When it names a known
/// editor we build a line-aware argv; otherwise — and when it's null
/// — we fall back to the OS file handler.
///
/// `argv_buf` must hold at least 8 slots; `scratch` at least 32 bytes
/// plus `file.len` (a `file:line` string). Both are borrowed for the
/// lifetime of the returned `Plan`.
pub fn planReveal(
    argv_buf: [][]const u8,
    scratch: []u8,
    editor_env: ?[]const u8,
    file: []const u8,
    line: u32,
) Plan {
    if (editor_env) |editor| {
        if (editor.len > 0) {
            if (classifyEditor(editor)) |kind| {
                if (composeEditorArgv(argv_buf, scratch, editor, kind, file, line)) |argv| {
                    return .{ .argv = argv, .has_line = true };
                }
            }
        }
    }
    return .{ .argv = osOpenArgv(argv_buf, file), .has_line = false };
}

/// Look up the editor command from the environment. Honours, in
/// order: `LABELLE_FLOW_EDITOR` (lets a user point flows at a
/// specific editor without disturbing `$EDITOR`), then `VISUAL`, then
/// `EDITOR`. Returns null when none is set.
///
/// The returned slice is owned by `allocator` — the caller frees it.
fn editorFromEnv(allocator: std.mem.Allocator) ?[]u8 {
    const env = io_global.environ();
    for ([_][]const u8{ "LABELLE_FLOW_EDITOR", "VISUAL", "EDITOR" }) |key| {
        const val = env.getAlloc(allocator, key) catch continue;
        if (val.len > 0) return val;
        allocator.free(val);
    }
    return null;
}

/// Allocator backing the heap `Child` handed to the detached reaper
/// thread. Deliberately **not** the app's GPA: the reaper outlives the
/// `reveal` call and a terminal editor keeps it alive for the whole
/// editing session, so it can still be in `wait`/freeing when `main`
/// runs `gpa.deinit()` on quit. `std.heap.c_allocator` is a global
/// libc allocator with no `deinit` and no leak-tracking teardown, so
/// the reaper can never race an allocator shutdown.
const reaper_allocator = std.heap.c_allocator;

/// Block on `child` until it exits, reaping it, then free `child`
/// itself. Runs on a detached background thread (see `reveal`) so the
/// blocking `wait` never touches the UI thread. `child` is heap-owned
/// by this thread (allocated from `reaper_allocator`); `io` is the
/// process-wide handle (valid for the program's lifetime).
fn reapChild(io: std.Io, child: *std.process.Child) void {
    // The launcher's exit status is irrelevant — `reveal` is
    // best-effort and already returned. We only `wait` to reap the
    // process so it doesn't linger as a zombie. A terminal editor
    // (or `code --wait`) keeps the child alive for the whole editing
    // session; that is exactly why this runs off the UI thread.
    _ = child.wait(io) catch {};
    reaper_allocator.destroy(child);
}

/// Open `file` at `line` in the user's editor (or the OS file
/// handler). The launcher is spawned on the calling thread — `spawn`
/// returns as soon as the child is forked, so the gui does not stall —
/// and is then reaped on a detached background thread so a long-lived
/// editor process never freezes the gui. Returns a value-only
/// `RevealResult`; a spawn failure surfaces synchronously as an error.
///
/// `allocator` backs only the env-derived editor string, freed before
/// `reveal` returns — nothing it allocates outlives the call. The
/// heap `Child` handed to the reaper thread uses `reaper_allocator`
/// (libc, no teardown) instead, so the detached reaper can never race
/// the app's `gpa.deinit()` on quit.
pub fn reveal(allocator: std.mem.Allocator, file: []const u8, line: u32) !RevealResult {
    var argv_buf: [8][]const u8 = undefined;
    // `file:line` is the longest scratch consumer — path + ':' + a
    // 10-digit u32 + slack.
    var scratch_buf: [std.fs.max_path_bytes + 16]u8 = undefined;

    const editor = editorFromEnv(allocator);
    defer if (editor) |e| allocator.free(e);
    // `plan` borrows `argv_buf` / `scratch_buf` / `editor` — all valid
    // here. `spawn` forks/exec's before it returns, so the argv only
    // needs to live across the `spawn` call; nothing about `plan`
    // escapes this function.
    const plan = planReveal(&argv_buf, &scratch_buf, editor, file, line);

    const io = io_global.io();
    var stack_child = std.process.spawn(io, .{
        .argv = plan.argv,
        .stdin = .ignore,
        // The launched process shouldn't inherit our std handles — a
        // terminal editor would otherwise fight the gui for stdin.
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return err;

    // Hand reaping to a detached background thread. `wait` blocks
    // until the launcher exits — for a GUI editor's CLI front-end
    // (`code`, `cursor`, `zed`) or an OS handler (`open` / `xdg-open`
    // / `cmd /c start`) that is immediate, but a terminal editor or a
    // `code --wait`-style `$EDITOR` stays alive for the whole editing
    // session. Doing this on the UI thread would freeze the gui for
    // exactly that long. The `Child` is heap-copied so it outlives
    // this stack frame; the reaper thread owns and frees it. It is
    // allocated from `reaper_allocator` (libc, no teardown) — not the
    // app GPA — so the detached reaper can never race `gpa.deinit()`.
    const child = reaper_allocator.create(std.process.Child) catch {
        // Out of memory for the 100-odd-byte handle — fall back to
        // reaping inline. The child is a launcher in the common case,
        // so this rarely blocks; under genuine OOM the gui has bigger
        // problems anyway.
        _ = stack_child.wait(io) catch {};
        return .{ .has_line = plan.has_line };
    };
    child.* = stack_child;
    const thread = std.Thread.spawn(.{}, reapChild, .{ io, child }) catch {
        // Could not spawn the reaper thread — reap inline rather than
        // leak the handle or the process.
        defer reaper_allocator.destroy(child);
        _ = child.wait(io) catch {};
        return .{ .has_line = plan.has_line };
    };
    thread.detach();

    return .{ .has_line = plan.has_line };
}

// Tests for `planReveal` / `programBasename` live in `src/tests.zig`
// (`FlowsRevealTests`) — the project keeps its zspec suites in one
// root file. `planReveal` is `pub` so the suite reaches it directly.
