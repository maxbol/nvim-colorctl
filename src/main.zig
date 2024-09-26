const std = @import("std");
const clap = @import("clap");
const nvim = @import("nvim.zig");
const socket = @import("socket.zig");
const color = @import("color.zig");

pub fn main() !void {
    var fixed_buffer: [10 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const allocator = fba.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Show this help message.
        \\-l, --list                    List all available color schemes.
        \\-s, --set <colorscheme>               Set the color scheme in all active editors.
        \\-b, --background <bg_mode>    Set the background mode (light/dark)
        \\--hi-fg <groupcolor>...       Set the foreground color of a highlight group (<group>,<hexcolor> format)
        \\--hi-bg <groupcolor>...       Set the foreground color of a highlight group (<group>,<hexcolor> format)
        \\--emit-vim <file>             Emit the cmd to set the colorscheme to a vimscript file
        \\--emit-lua <file>             Emit the cmd to set the colorscheme to a lua file
        \\
    );

    const parsers = comptime .{ .colorscheme = color.parseColorSchemeParam, .file = clap.parsers.string, .bg_mode = clap.parsers.enumeration(color.BgMode), .groupcolor = color.parseGroupColorParam };

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
        const editors = try socket.allocAllActiveEditors(allocator);
        if (editors.len == 0) {
            std.log.err("No active editors found. Make sure neovim is running.", .{});
            return error.NoActiveEditors;
        }
        const color_schemes = try color.getSystemColorSchemes(editors[0], allocator);
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

    var cmds = std.ArrayList([]const u8).init(allocator);

    if (res.args.set) |scheme| {
        try cmds.append(try color.allocPrintColorSchemeCmd(scheme, allocator));
    }

    if (res.args.background) |bg_mode| {
        try cmds.append(try color.allocPrintBgModeCmd(bg_mode, allocator));
    }

    for (res.args.@"hi-fg") |groupcolor| {
        try cmds.append(try color.allocPrintHighlightCmd(groupcolor.group, groupcolor.color, null, allocator));
    }

    for (res.args.@"hi-bg") |groupcolor| {
        try cmds.append(try color.allocPrintHighlightCmd(groupcolor.group, null, groupcolor.color, allocator));
    }

    if (cmds.items.len > 0) {
        const cmds_slice = try cmds.toOwnedSlice();

        const editors = try socket.allocAllActiveEditors(allocator);
        if (editors.len == 0) {
            std.log.err("No active editors found. Make sure neovim is running.", .{});
            return error.NoActiveEditors;
        }

        _ = try nvim.inputCmdKeysToEditors(editors, cmds_slice, allocator);

        if (res.args.@"emit-vim") |file| {
            const fpath = try color.allocPrintEmitFilePath(file, allocator);
            std.log.info("Emitting vimscript cmd to file: {s}\n", .{fpath});
            try color.emitCmds(cmds_slice, fpath, color.EmitType.VimScript, allocator);
        }

        if (res.args.@"emit-lua") |file| {
            const fpath = try color.allocPrintEmitFilePath(file, allocator);
            std.log.info("Emitting lua cmd to file: {s}\n", .{fpath});
            try color.emitCmds(cmds_slice, fpath, color.EmitType.Lua, allocator);
        }
        return;
    }

    return clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
}
