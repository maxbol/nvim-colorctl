const std = @import("std");

pub const CmdResult = struct {
    exit_code: u8,
    stdout: []const u8,
};

pub fn executeDuplexCmd(cmd: []const []const u8, allocator: std.mem.Allocator) !CmdResult {
    const process = try std.process.Child.run(.{
        .argv = cmd,
        .allocator = allocator,
    });

    const term = process.term;

    const exit_code = switch (term) {
        .Exited => |exit_code| exit_code,
        inline else => {
            return error.CmdFailed;
        },
    };

    return .{
        .stdout = process.stdout,
        .exit_code = exit_code,
    };
}
