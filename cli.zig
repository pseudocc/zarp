const std = @import("std");
const Z = @import("zargs");
const socket = @import("socket.zig");

const os = std.os.linux;

pub const List = struct {
    const Device = socket.Device;
    const Format = enum { json, name };
    const Sort = struct {
        by: ?enum { name, ip } = null,
        descent: bool = false,
    };

    format: Format = .name,
    sort: Sort = .{},
    descent: bool = false,

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
        .path = &.{ "sort", "by" },
        .parameter = .{ .named = .{
            .long = "sort-by",
            .short = 's',
            .metavar = "KIND",
        } },
        .description =
        \\Sort device by KIND ascending.
        ,
    };

    const arg_descent = Z.Final.Declaration{
        .path = &.{ "sort", "descent" },
        .parameter = .{ .named = .{
            .long = "descent",
            .short = 'd',
            .action = .{ .assign = &true },
        } },
        .description =
        \\Do sort in descending order.
        \\This is only valid if --sort-by is set.
        ,
    };

    pub const zargs = Z.Final{
        .args = &.{
            arg_json,
            arg_sort_by,
        },
        .summary = "List all lab devices.",
    };

    fn sortDevice(sort: Sort, lhs: Device, rhs: Device) bool {
        const Ip4 = @import("ARP.zig").Ip4;
        // write a comment here in case one day I am too dumb to
        // understand that boolean xor is equivalent to !=
        return sort.descent != switch (sort.by.?) {
            .name => switch (std.mem.order(u8, lhs.name, rhs.name)) {
                .lt => true,
                else => false,
            },
            .ip => std.mem.bigToNative(Ip4, lhs.ip) < std.mem.bigToNative(Ip4, rhs.ip),
        };
    }

    pub fn list(self: List) !void {
        const client = try socket.Client.init();
        defer client.deinit();

        const stdout = std.io.getStdOut().writer();
        const allocator = std.heap.page_allocator;

        if (try client.list(allocator)) |devices| {
            defer allocator.free(devices);
            if (self.sort.by) |_|
                std.sort.pdq(Device, @constCast(devices), self.sort, sortDevice);

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
    defer client.deinit();

    if (!try client.rescan())
        return error.RescanFailed;
}
