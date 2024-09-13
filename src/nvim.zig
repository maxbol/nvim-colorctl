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

fn allocMsgpackPayload(fn_name: []const u8, msg_id: u64, params: msgpack.Payload, allocator: std.mem.Allocator) !msgpack.Payload {
    var payload = try msgpack.Payload.arrPayload(4, allocator);

    try payload.setArrElement(0, msgpack.Payload.uintToPayload(@intFromEnum(MessageType.Request)));
    try payload.setArrElement(1, msgpack.Payload.uintToPayload(msg_id));
    try payload.setArrElement(2, try msgpack.Payload.strToPayload(fn_name, allocator));
    try payload.setArrElement(3, params);

    return payload;
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

pub fn executeCmdsInEditors(editors: []const []const u8, cmds: []const []const u8, allocator: std.mem.Allocator) !void {
    var streams = std.ArrayList(std.net.Stream).init(allocator);
    var packs = std.ArrayList(Pack).init(allocator);
    var msg_len = std.ArrayList(u64).init(allocator);
    var cmd_map = std.AutoHashMap(u64, []const u8).init(allocator);

    for (editors) |editor| {
        std.debug.print("Sending commands to editor {s}:\n", .{editor});
        const stream = try std.net.connectUnixSocket(editor);
        errdefer stream.close();

        const pack = Pack.init(stream, stream);

        var msg_id: u64 = 0;
        for (cmds) |cmd| {
            try cmd_map.put(msg_id, cmd);
            std.debug.print(" * {s}\n", .{cmd});
            executeCmdInEditor(pack, msg_id, cmd, allocator) catch {
                std.log.err("Failed to run command in editor: editor={s}, cmd={s}", .{ editor, cmd });
                return error.RunVimCmdFailed;
            };
            msg_id += 1;
        }
        std.debug.print("\n", .{});

        try streams.append(stream);
        try packs.append(pack);
        try msg_len.append(msg_id);
    }

    for (streams.items, 0..) |stream, index| {
        defer stream.close();

        const pack = packs.items[index];
        const no_of_msgs = msg_len.items[index];

        for (0..no_of_msgs) |_| {
            const response = try pack.read(allocator);

            const msg_id = try response.getArrElement(1);
            const err = try response.getArrElement(2);

            const cmd = switch (msg_id) {
                .uint => |id| cmd_map.get(id),
                else => null,
            };

            switch (err) {
                .nil => {},
                else => {
                    const msg = try err.getArrElement(1);
                    std.log.err("Failed to run command in editor: editor={s}, cmd={?s}, err={s}", .{ editors[index], cmd, msg.str.value() });
                },
            }
        }
    }
}
