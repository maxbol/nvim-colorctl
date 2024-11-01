const std = @import("std");
const msgpack = @import("msgpack");

const Pack = msgpack.Pack(std.net.Stream, std.net.Stream, std.net.Stream.WriteError, std.net.Stream.ReadError, std.net.Stream.write, std.net.Stream.read);

const NVIM_COMMAND = "nvim_command";
const NVIM_EVAL = "nvim_eval";
const NVIM_EXEC2 = "nvim_exec2";
const NVIM_INPUT = "nvim_input";

const MessageType = enum(u2) {
    Request = 0,
    Response = 1,
    Notification = 2,
};

fn allocMsgpackPayload(fn_name: []const u8, msg_id: u64, params: msgpack.Payload, allocator: std.mem.Allocator) !msgpack.Payload {
    var payload = try msgpack.Payload.arrPayload(4, allocator);

    try payload.setArrElement(0, msgpack.Payload.uintToPayload(@intFromEnum(MessageType.Request)));
    try payload.setArrElement(1, msgpack.Payload.uintToPayload(msg_id));
    try payload.setArrElement(2, try msgpack.Payload.strToPayload(fn_name, allocator));
    try payload.setArrElement(3, params);

    return payload;
}

fn inputToEditor(pack: Pack, msg_id: u64, keys: []const u8, allocator: std.mem.Allocator) !void {
    const nvim_feedkeys_req = blk: {
        var params = try msgpack.Payload.arrPayload(1, allocator);

        try params.setArrElement(0, try msgpack.Payload.strToPayload(keys, allocator));

        const payload = try allocMsgpackPayload(NVIM_INPUT, msg_id, params, allocator);

        break :blk payload;
    };

    try pack.write(nvim_feedkeys_req);
}

const ExecuteCmdInEditor2Opts = struct {
    output: bool = false,
};
fn executeCmdInEditor2(pack: Pack, msg_id: u64, src: []const u8, opts: ExecuteCmdInEditor2Opts, allocator: std.mem.Allocator) !void {
    const nvim_exec2_req = blk: {
        var params = try msgpack.Payload.arrPayload(2, allocator);
        var options = msgpack.Payload.mapPayload(allocator);

        try options.mapPut("output", msgpack.Payload.boolToPayload(opts.output));

        try params.setArrElement(0, try msgpack.Payload.strToPayload(src, allocator));
        try params.setArrElement(1, options);

        const payload = try allocMsgpackPayload(NVIM_EXEC2, msg_id, params, allocator);

        break :blk payload;
    };

    try pack.write(nvim_exec2_req);
}

fn executeCmdInEditor(pack: Pack, msg_id: u64, cmd: []const u8, allocator: std.mem.Allocator) !void {
    const nvim_cmd_req = blk: {
        var params = try msgpack.Payload.arrPayload(1, allocator);

        try params.setArrElement(0, try msgpack.Payload.strToPayload(cmd, allocator));

        const payload = try allocMsgpackPayload(NVIM_COMMAND, msg_id, params, allocator);

        break :blk payload;
    };

    try pack.write(nvim_cmd_req);
}

pub fn evalExprInEditor(editor: []const u8, expr: []const u8, allocator: std.mem.Allocator) !msgpack.Payload {
    const stream = try std.net.connectUnixSocket(editor);
    defer stream.close();

    const pack = Pack.init(stream, stream);

    const nvim_eval_req = blk: {
        var params = try msgpack.Payload.arrPayload(1, allocator);
        try params.setArrElement(0, try msgpack.Payload.strToPayload(expr, allocator));
        const payload = try allocMsgpackPayload(NVIM_EVAL, 0, params, allocator);
        break :blk payload;
    };

    try pack.write(nvim_eval_req);

    const response_payload = try pack.read(allocator);

    const err = try response_payload.getArrElement(2);

    switch (err) {
        .nil => {},
        else => {
            const msg = try err.getArrElement(1);
            std.log.err("Failed to run command in editor: editor={s}, cmd={s}, err={s}", .{ editor, expr, msg.str.value() });
        },
    }

    return response_payload.getArrElement(3);
}

pub fn inputCmdKeysToEditors(editors: []const []const u8, cmds: []const []const u8, allocator: std.mem.Allocator) !void {
    var streams = std.ArrayList(std.net.Stream).init(allocator);
    var packs = std.ArrayList(Pack).init(allocator);

    var cmd_buffer: [96 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buffer);
    const writer = fbs.writer();

    for (cmds) |cmd| {
        _ = try writer.write(":");
        _ = try writer.write(cmd);
        _ = try writer.write("<CR>");
    }

    const keys = fbs.getWritten();

    for (editors) |editor| {
        const stream = try std.net.connectUnixSocket(editor);
        errdefer stream.close();

        const pack = Pack.init(stream, stream);

        const msg_id: u64 = 0;

        inputToEditor(pack, msg_id, keys, allocator) catch {
            std.log.err("Failed to run command in editor: editor={s}, keys={s}", .{ editor, keys });
            return error.RunVimCmdFailed;
        };

        try streams.append(stream);
        try packs.append(pack);
    }

    for (streams.items, 0..) |stream, index| {
        defer stream.close();

        const pack = packs.items[index];

        const response = try pack.read(allocator);

        const err = try response.getArrElement(2);

        switch (err) {
            .nil => {},
            else => {
                const msg = try err.getArrElement(1);
                std.log.err("Failed to run command in editor: editor={s}, keys={?s}, err={s}", .{ editors[index], keys, msg.str.value() });
            },
        }
    }
}

pub fn executeCmdsInEditors(editors: []const []const u8, cmds: []const []const u8, allocator: std.mem.Allocator) !void {
    var streams = std.ArrayList(std.net.Stream).init(allocator);
    var packs = std.ArrayList(Pack).init(allocator);

    var vimscript_buffer: [96 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&vimscript_buffer);
    const writer = fbs.writer();

    _ = try writer.write(
        \\lua << EOF
        \\  vim.schedule(function()
        \\
    );

    for (cmds) |cmd| {
        _ = try writer.write("\t\tvim.cmd(\"");
        _ = try writer.write(cmd);
        _ = try writer.write("\")\n");
        std.debug.print(" * {s}\n", .{cmd});
    }
    std.debug.print("\n", .{});

    _ = try writer.write(
        \\  end)
        \\EOF
    );

    const cmd = fbs.getWritten();

    for (editors) |editor| {
        const stream = try std.net.connectUnixSocket(editor);
        errdefer stream.close();

        const pack = Pack.init(stream, stream);

        const msg_id: u64 = 0;

        executeCmdInEditor2(pack, msg_id, cmd, .{ .output = false }, allocator) catch {
            std.log.err("Failed to run command in editor: editor={s}, cmd={s}", .{ editor, cmd });
            return error.RunVimCmdFailed;
        };

        try streams.append(stream);
        try packs.append(pack);
    }

    for (streams.items, 0..) |stream, index| {
        defer stream.close();

        const pack = packs.items[index];

        const response = try pack.read(allocator);

        const err = try response.getArrElement(2);

        switch (err) {
            .nil => {},
            else => {
                const msg = try err.getArrElement(1);
                std.log.err("Failed to run command in editor: editor={s}, cmd={?s}, err={s}", .{ editors[index], cmd, msg.str.value() });
            },
        }
    }
}
