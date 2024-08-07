const std = @import("std");
const clap = @import("clap");
const nvim = @import("nvim.zig");

pub const CmdResult = struct {
    exit_code: u8,
    stdout: []const u8,
};

fn executeDuplexCmd(cmd: []const []const u8, allocator: std.mem.Allocator) !CmdResult {
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

fn allocAllActiveEditors(allocator: std.mem.Allocator) ![]const []const u8 {
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

fn allocPrintColorSchemeCmd(scheme: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var keys = std.ArrayList(u8).init(allocator);
    errdefer keys.deinit();

    try keys.appendSlice("colorscheme ");
    try keys.appendSlice(scheme);

    return keys.toOwnedSlice();
}

fn getSystemColorSchemes(editor: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    const payload = try nvim.evalExprInEditor(editor, "getcompletion(\"\", \"color\")", allocator);

    const arr_payload = switch (payload) {
        .arr => |arr| arr,
        else => {
            return error.CmdFailed;
        },
    };

    var result = std.ArrayList([]const u8).init(allocator);

    for (arr_payload) |p| {
        switch (p) {
            .str => |str| {
                try result.append(str.value());
            },
            else => {},
        }
    }

    return result.toOwnedSlice();
}

fn emitScriptFile(script_data: []const u8, file: []const u8) !void {
    var exists = true;
    std.fs.accessAbsolute(file, .{}) catch {
        exists = false;
    };

    if (exists == true) {
        _ = try std.fs.deleteFileAbsolute(file);
    }

    _ = try std.fs.createFileAbsolute(file, .{});

    const fh = try std.fs.openFileAbsolute(file, .{ .mode = .write_only });
    defer fh.close();

    try fh.writer().writeAll(script_data);
}

fn emitVimCmd(cmd: []const u8, file: []const u8) !void {
    try emitScriptFile(cmd, file);
}

fn emitLuaCmd(cmd: []const u8, file: []const u8) !void {
    var script_buf: [1024]u8 = undefined;
    const script_data = try std.fmt.bufPrint(&script_buf, "vim.cmd(\"{s}\")\n", .{cmd});
    try emitScriptFile(script_data, file);
}

fn allocPrintEmitFilePath(file: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    std.debug.assert(file.len != 0);
    if (file[1] == '/') {
        return file;
    }

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");

    const fpath = try std.fs.path.resolve(allocator, &.{ cwd_path, file });

    return fpath;
}

pub fn main() !void {
    var fixed_buffer: [10 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const allocator = fba.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help        Show this help message.
        \\-l, --list        List all available color schemes.
        \\-s, --set <str>   Set the color scheme in all active editors.
        \\--emit-vim <file> Emit the cmd to set the colorscheme to a vimscript file
        \\--emit-lua <file> Emit the cmd to set the colorscheme to a lua file
        \\
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        .file = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    if (res.args.list != 0) {
        const editors = try allocAllActiveEditors(allocator);
        if (editors.len == 0) {
            std.log.err("No active editors found. Make sure neovim is running.", .{});
            return error.NoActiveEditors;
        }
        const color_schemes = try getSystemColorSchemes(editors[0], allocator);
        const stdout = std.io.getStdOut();
        const writer = stdout.writer();

        _ = try writer.write("Available color schemes:\n\n");
        for (color_schemes) |scheme| {
            _ = try writer.write(" * ");
            _ = try writer.write(scheme);
            _ = try writer.writeByte('\n');
        }
        return;
    }

    if (res.args.set) |scheme| {
        const editors = try allocAllActiveEditors(allocator);
        if (editors.len == 0) {
            std.log.err("No active editors found. Make sure neovim is running.", .{});
            return error.NoActiveEditors;
        }
        const cmd = try allocPrintColorSchemeCmd(scheme, allocator);
        _ = try nvim.sendCmdToEditors(editors, cmd, allocator);

        if (res.args.@"emit-vim") |file| {
            const fpath = try allocPrintEmitFilePath(file, allocator);
            std.log.info("Emitting vimscript cmd to file: {s}\n", .{fpath});
            try emitVimCmd(cmd, fpath);
        }

        if (res.args.@"emit-lua") |file| {
            const fpath = try allocPrintEmitFilePath(file, allocator);
            std.log.info("Emitting lua cmd to file: {s}\n", .{fpath});
            try emitLuaCmd(cmd, fpath);
        }
        return;
    }

    return clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
}
