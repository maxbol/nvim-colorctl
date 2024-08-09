const std = @import("std");
const executeDuplexCmd = @import("cmd.zig").executeDuplexCmd;

fn allocParseProcessSocket(process_data: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var curr_start: usize = 0;
    var last_chr_blank = false;

    var cols = std.ArrayList([]const u8).init(allocator);

    for (process_data, 0..) |char, index| {
        if (index == process_data.len - 1) {
            try cols.append(process_data[curr_start..process_data.len]);
        } else if (char == '\t' or char == ' ') {
            if (last_chr_blank == true) {
                continue;
            }

            try cols.append(process_data[curr_start..index]);

            last_chr_blank = true;
        } else if (last_chr_blank == true) {
            last_chr_blank = false;
            curr_start = index;
        }
    }

    return cols.toOwnedSlice();
}

pub fn allocAllActiveEditors(allocator: std.mem.Allocator) ![]const []const u8 {
    const list_unix_sockets_raw_result = try executeDuplexCmd(&.{ "lsof", "-U" }, allocator);

    if (list_unix_sockets_raw_result.exit_code != 0) {
        std.log.err("lsof exited with non-zero exit code: errorcode={d}, errormsg={s}", .{ list_unix_sockets_raw_result.exit_code, list_unix_sockets_raw_result.stdout });
        return error.CmdFailed;
    }

    var editors = std.ArrayList([]const u8).init(allocator);
    errdefer editors.deinit();

    var curr_start: usize = 0;
    for (list_unix_sockets_raw_result.stdout, 0..) |char, index| {
        if (char == '\n') {
            // Skip header row
            if (curr_start == 0) {
                curr_start = index + 1;
                continue;
            }

            const entry = list_unix_sockets_raw_result.stdout[curr_start..index];
            const entry_cols = try allocParseProcessSocket(entry, allocator);

            curr_start = index + 1;

            const p_name = entry_cols[0];
            const p_socket = entry_cols[7];

            if (!std.mem.eql(u8, p_name, "nvim")) {
                continue;
            }

            if (p_socket[0] != '/') {
                continue;
            }

            try editors.append(p_socket);
        }
    }

    return editors.toOwnedSlice();
}
