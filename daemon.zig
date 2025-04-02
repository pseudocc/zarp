const std = @import("std");
const Z = @import("zargs");
const ARP = @import("ARP.zig");
const ssh = @import("ssh.zig");
const netlink = @import("netlink.zig");
const socket = @import("socket.zig");

const os = std.os.linux;
const log = std.log;

fn findNetdev(maybe_name: ?[:0]const u8) !ARP.Device {
    var buffer: [4096]u8 align(4) = undefined;
    var interface: []const u8 = maybe_name orelse "";
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
                        const this_interface = attr.asSlice(u8, 0);

                        if (interface.len == 0 and !iff.loopback and is_up) {
                            log.info("auto detected interface: {s}", .{this_interface});
                            interface = this_interface;
                            found = true;
                            continue;
                        }

                        found = std.mem.eql(u8, interface, this_interface);
                        if (!found)
                            continue;

                        log.debug("interface: {s} flags: {}", .{ interface, iff });
                        if (!is_up)
                            return error.InterfaceDown;
                    },
                    else => {},
                }
            }

            if (!found)
                continue;

            if (address == null or broadcast == null) {
                log.err("interface: {s} missing address or broadcast", .{interface});
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
                log.err("interface: {s} missing ip4", .{interface});
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

pub const Daemon = struct {
    const PrivateKey = struct {
        const Error = Z.ParseError;
        path: Z.string,
        passphrase: ?Z.string,

        pub fn parse(input: []const u8, allocator: std.mem.Allocator) Error!PrivateKey {
            if (std.mem.indexOfScalar(u8, input, ':')) |i| {
                const path = try allocator.dupeZ(u8, input[0..i]);
                const passphrase = try allocator.dupeZ(u8, input[i + 1 ..]);
                return .{ .path = path, .passphrase = passphrase };
            }
            const path = try allocator.dupeZ(u8, input);
            return .{ .path = path, .passphrase = null };
        }

        pub const help_type = "string[:string]";
    };

    interface: ?Z.string = null,
    user: ?Z.string,
    key: PrivateKey,
    interval: u32 = 5,

    const arg_interface = Z.Final.Declaration{
        .path = &.{"interface"},
        .parameter = .{ .named = .{
            .long = "interface",
            .short = 'i',
            .metavar = "IFNAME",
        } },
        .description =
        \\Network interface to monitor, will pick the first
        \\available interface if not specified.
        ,
    };

    const arg_key = Z.Final.Declaration{
        .path = &.{"key"},
        .parameter = .{ .named = .{
            .long = "key",
            .short = 'k',
            .metavar = "FILE[:PASSPHRASE]",
        } },
        .description =
        \\Private key file for ssh authentication,
        \\append passphrase after colon if applicable.
        ,
    };

    const arg_user = Z.Final.Declaration{
        .path = &.{"user"},
        .parameter = .{ .named = .{
            .long = "user",
            .short = 'u',
            .metavar = "USER",
        } },
        .description =
        \\User that logs into lab devices, will use the
        \\current user if not specified.
        ,
    };

    const arg_interval = Z.Final.Declaration{
        .path = &.{"interval"},
        .parameter = .{ .named = .{
            .long = "interval",
            .short = 't',
            .metavar = "SECONDS",
        } },
        .description =
        \\Scan interval in seconds, default is 5 seconds.
        ,
    };

    pub const zargs = Z.Final{
        .args = &.{
            arg_key,
            arg_interface,
            arg_user,
            arg_interval,
        },
        .summary = "ARP daemon for lab device discovery.",
    };

    pub fn listen(self: Daemon) !void {
        const allocator = std.heap.page_allocator;
        const user = self.user orelse (std.posix.getenv("USER") orelse return error.MissingUser);
        const netdev = try findNetdev(self.interface);

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

        const key = try ssh.Key.init(self.key.path, self.key.passphrase);
        defer key.deinit();

        const arp = try ARP.init(netdev);
        defer arp.deinit();

        const zarpd = try socket.Daemon.init();
        defer zarpd.deinit();

        var last_scan: i64 = 0;
        var force_scan: bool = false;
        while (true) {
            if (zarpd.accept() catch null) |response| switch (response.request) {
                .list => {
                    const n_labdevs = z: {
                        var n: usize = 0;
                        for (devices) |dev| {
                            if (dev.info) |info| {
                                if (info.lab_device)
                                    n += 1;
                            }
                        }
                        break :z n;
                    };

                    const labdevs = try allocator.alloc(socket.Device, n_labdevs);
                    defer allocator.free(labdevs);

                    var i: usize = 0;
                    for (devices) |dev| {
                        if (dev.info) |info| {
                            if (info.lab_device) {
                                labdevs[i] = .{
                                    .ip = dev.ip,
                                    .mac = info.mac,
                                    .name = info.name,
                                };
                                i += 1;
                            }
                        }
                    }

                    response.list(labdevs) catch |err| {
                        log.err("list devices: {}", .{err});
                    };
                },
                .rescan => {
                    force_scan = true;
                    last_scan = 0;
                    response.ok(true) catch |err| {
                        log.err("force rescan: {}", .{err});
                    };
                },
            };

            const now = std.time.timestamp();
            if (now - last_scan < self.interval)
                continue;

            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = allocator });
            defer {
                pool.deinit();
                last_scan = now;
            }

            for (devices) |dev| {
                if (!force_scan and !dev.refresh())
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
                    user,
                    key,
                }) catch continue;
            }
        }
    }
};

pub const Device = struct {
    const LAB_DEVICE_TTL = 60;
    const UNKNOWN_DEVICE_TTL = 15;

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
        defer channel.deinit();
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
