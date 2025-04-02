const std = @import("std");
const Z = @import("zargs");
const socket = @import("socket.zig");

const os = std.os.linux;

pub const List = struct {
    const Format = enum { json, name };

    format: Format = .name,

    const arg_json = Z.Final.Declaration{
        .path = &.{"format"},
        .parameter = .{ .named = .{
            .long = "json",
            .short = 'j',
            .action = .{ .assign = &Format.json },
        } },
        .description =
        \\Output in JSON format instead of names.
        ,
    };

    pub const zargs = Z.Final{
        .args = &.{arg_json},
        .summary = "List all lab devices.",
    };

    pub fn list(self: List) !void {
        const client = try socket.Client.init();
        const stdout = std.io.getStdOut().writer();
        const allocator = std.heap.page_allocator;

        if (try client.list(allocator)) |devices| {
            defer allocator.free(devices);
            switch (self.format) {
                .name => for (devices) |device| {
                    try stdout.print("{s}\n", .{device.name});
                },
                .json => try std.json.stringify(devices, .{}, stdout),
            }
        }
    }
};

pub fn rescan() !void {
    const client = try socket.Client.init();
    if (!try client.rescan())
        return error.RescanFailed;
}
