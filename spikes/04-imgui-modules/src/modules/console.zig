const std = @import("std");
const zgui = @import("zgui");
const module = @import("../module.zig");

var is_open: bool = true;
var log_buffer: [4096]u8 = undefined;
var log_len: usize = 0;
var input_buffer: [256:0]u8 = [_:0]u8{0} ** 256;

pub fn init() void {
    appendLog("Console initialized\n");
    appendLog("Type 'help' for commands\n");
}

pub fn deinit() void {}

fn appendLog(msg: []const u8) void {
    const remaining = log_buffer.len - log_len;
    const to_copy = @min(msg.len, remaining);
    @memcpy(log_buffer[log_len .. log_len + to_copy], msg[0..to_copy]);
    log_len += to_copy;
}

fn renderPanel() void {
    // Output area
    if (zgui.beginChild("ConsoleOutput", .{ .h = -30 })) {
        zgui.textWrapped("{s}", .{log_buffer[0..log_len]});
        if (zgui.getScrollY() >= zgui.getScrollMaxY()) {
            zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
        }
    }
    zgui.endChild();

    zgui.separator();

    // Input line
    zgui.setNextItemWidth(-60);
    const enter_pressed = zgui.inputText("##input", .{
        .buf = &input_buffer,
        .flags = .{ .enter_returns_true = true },
    });

    zgui.sameLine(.{});

    if (zgui.button("Send", .{ .w = 50 }) or enter_pressed) {
        const cmd = std.mem.sliceTo(&input_buffer, 0);
        if (cmd.len > 0) {
            appendLog("> ");
            appendLog(cmd);
            appendLog("\n");

            // Simple command handling
            if (std.mem.eql(u8, cmd, "help")) {
                appendLog("Available commands:\n");
                appendLog("  help  - Show this help\n");
                appendLog("  clear - Clear console\n");
                appendLog("  time  - Show current time\n");
            } else if (std.mem.eql(u8, cmd, "clear")) {
                log_len = 0;
            } else if (std.mem.eql(u8, cmd, "time")) {
                appendLog("Time: (not implemented)\n");
            } else {
                appendLog("Unknown command: ");
                appendLog(cmd);
                appendLog("\n");
            }

            @memset(&input_buffer, 0);
        }
    }
}

pub const console_module = module.Module{
    .name = "console",
    .display_name = "Console",
    .render_panel = renderPanel,
    .is_open = &is_open,
    .on_init = init,
    .on_deinit = deinit,
};
