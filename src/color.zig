const std = @import("std");
const nvim = @import("nvim.zig");

pub const BgMode = enum {
    light,
    dark,
};

pub const EmitType = enum { VimScript, Lua };

pub const GroupColor = struct {
    group: []const u8,
    color: []const u8,
};

pub fn parseColorSchemeParam(in: []const u8) ![]const u8 {
    for (in) |c| {
        if ((c < 'a' or c > 'z') and (c < 'A' or c > 'Z') and (c < '0' or c > '9') and c != '_' and c != '-') {
            std.log.err("Not a valid color scheme name. Expected [a-zA-Z0-9_-]+", .{});
            return error.NotAValidColorScheme;
        }
    }
    return in;
}

pub fn parseGroupColorParam(in: []const u8) !GroupColor {
    var sep_index: ?usize = undefined;
    for (in, 0..) |c, i| {
        if (c == ',') {
            sep_index = i;
            break;
        }
    }

    if (sep_index) |idx| {
        const group = in[0..idx];
        const color = in[idx + 1 ..];

        if (color.len != 7 or color[0] != '#') {
            std.log.err("Not a valid color format. Expected #RRGGBB", .{});
            return error.NotAValidGroupColor;
        }

        for (color[1..]) |c| {
            if ((c < '0' or c > '9') and (c < 'a' or c > 'f')) {
                std.log.err("Not a valid color format. Expected #RRGGBB", .{});
                return error.NotAValidGroupColor;
            }
        }

        for (group) |c| {
            if ((c < 'a' or c > 'z') and (c < 'A' or c > 'Z') and (c < '0' or c > '9') and c != '_') {
                std.log.err("Not a valid group name. Expected [a-zA-Z0-9_]+", .{});
                return error.NotAValidGroupColor;
            }
        }

        return GroupColor{ .group = group, .color = color };
    } else {
        return error.NotAValidGroupColor;
    }
}

pub fn allocPrintColorSchemeCmd(scheme: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var keys = std.ArrayList(u8).init(allocator);
    errdefer keys.deinit();

    try keys.appendSlice("colorscheme ");
    try keys.appendSlice(scheme);

    return keys.toOwnedSlice();
}

pub fn allocPrintBgModeCmd(bg_mode: BgMode, allocator: std.mem.Allocator) ![]const u8 {
    var keys = std.ArrayList(u8).init(allocator);
    errdefer keys.deinit();

    try keys.appendSlice("set background=");
    try keys.appendSlice(if (bg_mode == BgMode.light) "light" else "dark");

    return keys.toOwnedSlice();
}

pub fn allocPrintHighlightCmd(highlight_group: []const u8, guifg: ?[]const u8, guibg: ?[]const u8, allocator: std.mem.Allocator) ![]const u8 {
    std.debug.assert(guifg != null or guibg != null);

    var keys = std.ArrayList(u8).init(allocator);
    errdefer keys.deinit();

    try keys.appendSlice("hi ");
    try keys.appendSlice(highlight_group);

    if (guifg) |color| {
        try keys.appendSlice(" guifg=");
        try keys.appendSlice(color);
    }

    if (guibg) |color| {
        try keys.appendSlice(" guibg=");
        try keys.appendSlice(color);
    }

    return keys.toOwnedSlice();
}

pub fn getSystemColorSchemes(editor: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
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

pub fn emitScriptFile(script_data: []const u8, file: []const u8) !void {
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

pub fn emitCmds(cmds: []const []const u8, file: []const u8, emit_type: EmitType, allocator: std.mem.Allocator) !void {
    var script_data_al = std.ArrayList(u8).init(allocator);
    for (cmds, 0..) |cmd, index| {
        if (index != 0) {
            try script_data_al.appendSlice("\r\n");
        }
        if (emit_type == .VimScript) {
            try script_data_al.appendSlice(cmd);
        } else {
            try script_data_al.appendSlice(try std.fmt.allocPrint(allocator, "vim.cmd(\"{s}\")", .{cmd}));
        }
    }
    try emitScriptFile(try script_data_al.toOwnedSlice(), file);
}

pub fn allocPrintEmitFilePath(file: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    std.debug.assert(file.len != 0);
    if (file[1] == '/') {
        return file;
    }

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");

    const fpath = try std.fs.path.resolve(allocator, &.{ cwd_path, file });

    return fpath;
}
