const std = @import("std");
const ARP = @import("ARP.zig");
const netlink = @import("netlink.zig");
const os = std.os.linux;
const ssh = @import("ssh.zig");

const log = std.log;
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

fn find(name: [:0]const u8) !ARP.Device {
    var buffer: [4096]u8 align(4) = undefined;
    var result: ARP.Device = undefined;
    const request = netlink.Request.init(&buffer);

    link: {
        var msg_iter = try request.get(.RTM_GETLINK);
        defer msg_iter.deinit();

        while (try msg_iter.next()) |msg| {
            if (msg.header.type != .RTM_NEWLINK)
                continue;

            const infomsg = msg.as(os.ifinfomsg);
            var address: ?ARP.Mac = null;
            var broadcast: ?ARP.Mac = null;
            var found = false;

            var attr_iter = msg.attributes();
            while (attr_iter.next()) |attr| {
                switch (attr.header.type.link) {
                    .ADDRESS => address = attr.as(ARP.Mac).*,
                    .BROADCAST => broadcast = attr.as(ARP.Mac).*,
                    .IFNAME => {
                        const iff: ARP.IFF = @bitCast(infomsg.flags);
                        const is_up = iff.up and iff.running and iff.lowerup;
                        const ifname = attr.asSlice(u8, 0);
                        if (name.len == 0 and !iff.loopback and is_up) {
                            log.info("auto detected interface: {s}", .{ifname});
                            found = true;
                            continue;
                        }
                        found = std.mem.eql(u8, name, ifname);
                        if (!found)
                            continue;
                        log.debug("interface: {s} flags: {}", .{ name, iff });
                        if (!is_up)
                            return error.InterfaceDown;
                    },
                    else => {},
                }
            }

            if (!found)
                continue;

            if (address == null or broadcast == null) {
                log.err("interface: {s} missing address or broadcast", .{name});
                return error.MissingHardwareAddress;
            }

            result.index = infomsg.index;
            result.hardware = .{
                .address = address.?,
                .broadcast = broadcast.?,
            };
            break :link;
        }

        return error.InterfaceNotFound;
    }

    addr: {
        var msg_iter = try request.get(.RTM_GETADDR);
        defer msg_iter.deinit();

        while (try msg_iter.next()) |msg| {
            if (msg.header.type != .RTM_NEWADDR)
                continue;

            const addrmsg = msg.as(netlink.ifaddrmsg);
            if (addrmsg.index != result.index or addrmsg.family != os.AF.INET)
                continue;

            result.ip = ip: {
                var attr_iter = msg.attributes();
                while (attr_iter.next()) |attr| {
                    switch (attr.header.type.addr) {
                        .LOCAL => break :ip attr.as(ARP.Ip4).*,
                        else => {},
                    }
                }
                log.err("interface: {s} missing ip4", .{name});
                return error.MissingIp4Address;
            };
            result.index = addrmsg.index;
            result.prefix_len = addrmsg.prefix_len;
            break :addr;
        }

        return error.InterfaceNotFound;
    }

    return result;
}

const Device = struct {
    const LAB_DEVICE_TTL = 600;
    const UNKNOWN_DEVICE_TTL = 60;

    const Info = struct {
        name: []const u8,
        mac: ARP.Mac,
        lab_device: bool,
        last_seen: i64,
    };

    ip: ARP.Ip4,
    allocator: std.mem.Allocator,
    info: ?Info = null,

    fn refresh(dev: Device) bool {
        if (dev.info) |info| {
            const elapsed = std.time.timestamp() - info.last_seen;
            return if (info.lab_device)
                elapsed > LAB_DEVICE_TTL
            else
                elapsed > UNKNOWN_DEVICE_TTL;
        }
        return true;
    }

    fn update(dev: *Device, mac: ARP.Mac, user: [:0]const u8, key: ssh.Key) !void {
        var buffer: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&buffer, "{}", .{ARP.stringify(dev.ip)}) catch unreachable;

        const now = std.time.timestamp();
        const session = ssh.Session.init(host, user, key) catch {
            dev.info = .{
                .name = &.{},
                .mac = mac,
                .lab_device = false,
                .last_seen = now,
            };
            log.debug("not a lab device: {s}", .{host});
            return;
        };
        defer session.deinit();

        const channel = try session.channel();
        try channel.exec("hostname");

        var stream = std.io.fixedBufferStream(&buffer);
        try channel.read(stream.writer(), .stdout);

        const hostname = std.mem.trimRight(u8, stream.getWritten(), "\n");
        if (dev.info) |info| {
            if (!info.lab_device)
                dev.allocator.free(info.name);
        }
        dev.info = .{
            .name = try dev.allocator.dupe(u8, hostname),
            .mac = mac,
            .lab_device = true,
            .last_seen = now,
        };
        log.info("lab device: {s}", .{hostname});
    }

    fn runUpdate(dev: *Device, mac: ARP.Mac, user: [:0]const u8, key: ssh.Key) void {
        dev.update(mac, user, key) catch |err| {
            log.err("update {}: {}", .{ ARP.stringify(dev.ip), err });
        };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const netdev = try find(&.{});
    const private_key_path = std.mem.sliceTo(std.os.argv[1], 0);

    const host_bits: u5 = @intCast(32 - netdev.prefix_len);
    const network = std.mem.bigToNative(ARP.Ip4, netdev.ip) & (~@as(ARP.Ip4, 0) << host_bits);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const devices: []Device = z: {
        const n_hosts = @as(u32, 1) << host_bits;
        const array = try allocator.alloc(Device, n_hosts - 1);
        for (array, 0..) |*dev, i| {
            const current: ARP.Ip4 = @intCast(network + i + 1);
            dev.* = .{
                .ip = std.mem.nativeToBig(ARP.Ip4, current),
                .allocator = arena.allocator(),
                .info = null,
            };
        }
        break :z array;
    };
    defer allocator.free(devices);

    const key = try ssh.Key.init(private_key_path, "foss");
    defer key.deinit();

    const arp = try ARP.init(netdev);
    defer arp.deinit();

    while (true) {
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = allocator });
        defer pool.deinit();
        defer std.Thread.sleep(std.time.ns_per_s * 5);

        for (devices) |dev| {
            if (!dev.refresh())
                continue;
            arp.send(dev.ip) catch {};
        }

        var timed_out: u8 = 0;
        while (timed_out < 5) {
            var pollfd = os.pollfd{
                .fd = arp.socket,
                .events = os.POLL.IN,
                .revents = 0,
            };

            if (os.poll(@ptrCast(&pollfd), 1, 100) <= 0) {
                timed_out += 1;
                continue;
            }

            const packet = arp.receive() catch |err| {
                if (err == error.NotReply)
                    continue;
                return err;
            };

            const native_ip = std.mem.bigToNative(ARP.Ip4, packet.sender.ip);
            if (native_ip < network + 1)
                continue;
            const i = native_ip - network - 1;
            if (i >= devices.len)
                continue;

            pool.spawn(Device.runUpdate, .{
                &devices[i],
                packet.sender.mac,
                "u",
                key,
            }) catch continue;
        }

        var n_lab_devices: usize = 0;
        for (devices) |dev| {
            if (dev.info) |info| {
                if (info.lab_device) {
                    n_lab_devices += 1;
                    log.debug("{} {s}", .{ ARP.stringify(dev.ip), info.name });
                }
            }
        }
        log.debug("online lab devices: {}", .{n_lab_devices});
    }
}
