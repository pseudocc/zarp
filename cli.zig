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
    const Status = enum {
        online,
        offline,
        all,
    };

    format: Format = .name,
    sort: Sort = .{},
    descent: bool = false,
    status: Status = .online,

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

    const arg_online = Z.Final.Declaration{
        .path = &.{"status"},
        .parameter = .{ .named = .{
            .long = "online",
            .action = .{ .assign = &Status.online },
        } },
        .description =
        \\Only show online devices (default).
        ,
    };

    const arg_offline = Z.Final.Declaration{
        .path = &.{"status"},
        .parameter = .{ .named = .{
            .long = "offline",
            .action = .{ .assign = &Status.offline },
        } },
        .description =
        \\Only show offline devices.
        ,
    };

    const arg_all = Z.Final.Declaration{
        .path = &.{"status"},
        .parameter = .{ .named = .{
            .long = "all",
            .action = .{ .assign = &Status.all },
        } },
        .description =
        \\Show all devices (online and offline).
        ,
    };

    pub const zargs = Z.Final{
        .args = &.{
            arg_json,
            arg_sort_by,
            arg_descent,
            arg_online,
            arg_offline,
            arg_all,
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

            var filtered_devices = try std.ArrayList(Device).initCapacity(allocator, devices.len);
            defer filtered_devices.deinit();
            for (devices) |device| {
                switch (self.status) {
                    .online => if (!device.online) continue,
                    .offline => if (device.online) continue,
                    .all => {},
                }
                filtered_devices.append(device) catch unreachable;
            }

            switch (self.format) {
                .name => for (filtered_devices.items) |device| {
                    try stdout.print("{s}\n", .{device.name});
                },
                .json => try std.json.stringify(filtered_devices.items, .{}, stdout),
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
