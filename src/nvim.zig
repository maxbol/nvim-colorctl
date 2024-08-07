const std = @import("std");
const msgpack = @import("msgpack");

const Pack = msgpack.Pack(std.net.Stream, std.net.Stream, std.net.Stream.WriteError, std.net.Stream.ReadError, std.net.Stream.write, std.net.Stream.read);

const NVIM_COMMAND = "nvim_command";
const NVIM_EVAL = "nvim_eval";

const MessageType = enum(u2) {
    Request = 0,
    Response = 1,
    Notification = 2,
};

var msg_id: u64 = 0;

fn allocMsgpackPayload(fn_name: []const u8, params: msgpack.Payload, allocator: std.mem.Allocator) !msgpack.Payload {
    var payload = try msgpack.Payload.arrPayload(4, allocator);

    try payload.setArrElement(0, msgpack.Payload.uintToPayload(@intFromEnum(MessageType.Request)));
    try payload.setArrElement(1, msgpack.Payload.uintToPayload(msg_id));
    try payload.setArrElement(2, try msgpack.Payload.strToPayload(fn_name, allocator));
    try payload.setArrElement(3, params);

    msg_id += 1;

    return payload;
}

fn sendCmdToEditor(pack: Pack, cmd: []const u8, allocator: std.mem.Allocator) !void {
    const nvim_cmd_req = blk: {
        var params = try msgpack.Payload.arrPayload(1, allocator);

        try params.setArrElement(0, try msgpack.Payload.strToPayload(cmd, allocator));

        const payload = try allocMsgpackPayload(NVIM_COMMAND, params, allocator);

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
        const payload = try allocMsgpackPayload(NVIM_EVAL, params, allocator);
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

pub fn sendCmdToEditors(editors: []const []const u8, cmd: []const u8, allocator: std.mem.Allocator) !void {
    var streams = std.ArrayList(std.net.Stream).init(allocator);
    var packs = std.ArrayList(Pack).init(allocator);

    for (editors) |editor| {
        const stream = try std.net.connectUnixSocket(editor);
        errdefer stream.close();

        const pack = Pack.init(stream, stream);

        sendCmdToEditor(pack, cmd, allocator) catch {
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
                std.log.err("Failed to run command in editor: editor={s}, cmd={s}, err={s}", .{ editors[index], cmd, msg.str.value() });
            },
        }
    }
}
