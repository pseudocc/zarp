const std = @import("std");
const Z = @import("zargs");
const socket = @import("socket.zig");

const os = std.os.linux;

pub const List = struct {
    const Device = socket.Device;
    const Format = enum { json, name };
    const SortBy = enum { name, ip };

    format: Format = .name,
    sort_by: ?SortBy = null,

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

    const arg_sort_by = Z.Final.Declaration{
        .path = &.{"sort_by"},
        .parameter = .{ .named = .{
            .long = "sort-by",
            .short = 's',
            .metavar = "KIND",
        } },
        .description =
        \\Sort device by KIND ascending.
        ,
    };

    pub const zargs = Z.Final{
        .args = &.{
            arg_json,
            arg_sort_by,
        },
        .summary = "List all lab devices.",
    };

    fn sortDevice(sort_by: SortBy, lhs: Device, rhs: Device) bool {
        const Ip4 = @import("ARP.zig").Ip4;
        return switch (sort_by) {
            .name => switch (std.mem.order(u8, lhs.name, rhs.name)) {
                .lt => true,
                else => false,
            },
            .ip => std.mem.bigToNative(Ip4, lhs.ip) < std.mem.bigToNative(Ip4, rhs.ip),
        };
    }

    pub fn list(self: List) !void {
        const client = try socket.Client.init();
        const stdout = std.io.getStdOut().writer();
        const allocator = std.heap.page_allocator;

        if (try client.list(allocator)) |devices| {
            defer allocator.free(devices);
            if (self.sort_by) |sort_by|
                std.sort.pdq(Device, @constCast(devices), sort_by, sortDevice);

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
