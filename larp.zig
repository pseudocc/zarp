const std = @import("std");
const ARP = @import("ARP.zig");
const netlink = @import("netlink.zig");
const os = std.os.linux;
const ssh = @import("ssh.zig");

const log = std.log;

fn find(name: []const u8) !ARP.Device {
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
                        found = std.mem.eql(u8, name, attr.asSlice(u8, 0));
                        if (!found)
                            continue;
                        const iff: ARP.IFF = @bitCast(infomsg.flags);
                        log.debug("interface: {s} flags: {}", .{ name, iff });
                        if (!iff.up or !iff.running or !iff.lowerup) {
                            return error.InterfaceDown;
                        }
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
    info: ?Info = null,

    fn refresh(dev: Device) bool {
        if (dev.info) |info| {
            const elapsed = std.time.timestamp() - info.last_seen;
            return if (info.lab_device)
                elapsed < LAB_DEVICE_TTL
            else
                elapsed < UNKNOWN_DEVICE_TTL;
        }
        return true;
    }
};

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    const allocater = std.heap.page_allocator;
    const netdev = try find("wlp9s0f0");

    const host_bits: u5 = @intCast(32 - netdev.prefix_len);
    const network = std.mem.bigToNative(ARP.Ip4, netdev.ip) & (~@as(ARP.Ip4, 0) << host_bits);

    const devices: []Device = z: {
        const n_hosts = @as(u32, 1) << host_bits;
        const array = try allocater.alloc(Device, n_hosts - 1);
        for (array, 0..) |*dev, i| {
            const current: ARP.Ip4 = @intCast(network + i + 1);
            dev.ip = std.mem.nativeToBig(ARP.Ip4, current);
            dev.info = null;
        }
        break :z array;
    };
    defer allocater.free(devices);

    const session = try ssh.Session.init("10.106.5.40", "u", "u");
    defer session.deinit();
    const channel = try session.channel();
    try channel.exec("hostname");
    try channel.read(stdout, .stdout);

    const arp = try ARP.init(netdev);
    defer arp.deinit();

    while (true) {
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

            const i = std.mem.bigToNative(ARP.Ip4, packet.sender.ip) - network - 1;
            devices[i].info = .{
                .name = "unknown",
                .mac = packet.sender.mac,
                .lab_device = false,
                .last_seen = std.time.timestamp(),
            };
        }

        for (devices) |dev| {
            if (dev.info) |info| {
                log.info("{} {s}", .{ ARP.stringify(dev.ip), info.name });
            }
        }
    }
}
