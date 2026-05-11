//! Shared byte-level ZON scanner helpers.
//!
//! Both `project.zig` (for `project.labelle`'s unmodeled fields) and
//! `gizmo_io.zig` (for gizmo `.entity` / `.children` blocks) need to
//! skip whitespace + `// ...` comments and walk a ZON value while
//! respecting `"..."` strings, `\"` escapes, and brace / bracket /
//! paren nesting. The two copies had drifted toward divergence; keep
//! them here so a fix lands once.
//!
//! Dialect handled:
//! - whitespace + line comments (`// ... \n`)
//! - `"..."` strings with `\"` and other one-char backslash escapes
//! - matched `{}` / `[]` / `()` nesting
//!
//! Not handled (no current schema needs them — extend if that changes):
//! - multi-line strings (`\\...`)
//! - `'...'` character literals

const std = @import("std");

/// Advance `i` past whitespace and `// ... \n` line comments.
pub fn skipWsAndComments(raw: []const u8, i: *usize) void {
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i.* += 1;
        } else if (c == '/' and i.* + 1 < raw.len and raw[i.* + 1] == '/') {
            while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
        } else break;
    }
}

/// Advance `i` over one ZON value expression. Stops at the byte after
/// the value — at the next top-level `,` or at the outer closing
/// bracket (which is *not* consumed). Strings, comments, and nested
/// containers are walked without bailing.
pub fn scanValue(raw: []const u8, i: *usize) void {
    var depth: usize = 0;
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c == '"') {
            i.* += 1;
            while (i.* < raw.len) {
                if (raw[i.*] == '\\' and i.* + 1 < raw.len) {
                    i.* += 2;
                } else if (raw[i.*] == '"') {
                    i.* += 1;
                    break;
                } else {
                    i.* += 1;
                }
            }
        } else if (c == '/' and i.* + 1 < raw.len and raw[i.* + 1] == '/') {
            while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
        } else if (c == '{' or c == '[' or c == '(') {
            depth += 1;
            i.* += 1;
        } else if (c == '}' or c == ']' or c == ')') {
            if (depth == 0) return; // outer `}` — stop without consuming
            depth -= 1;
            i.* += 1;
        } else if (c == ',' and depth == 0) {
            return;
        } else {
            i.* += 1;
        }
    }
}
