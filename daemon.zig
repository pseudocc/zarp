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

        var threads: std.Thread.Pool = undefined;
        try threads.init(.{ .allocator = allocator, .n_jobs = 0 });

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
                    const online_bound = std.time.timestamp() - Device.LAB_DEVICE_TTL * 2;
                    for (devices) |dev| {
                        if (dev.info) |info| {
                            if (info.lab_device) {
                                labdevs[i] = .{
                                    .ip = dev.ip,
                                    .mac = info.mac,
                                    .name = info.name,
                                    .online = info.last_seen > online_bound,
                                    .details = info.details,
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

            defer last_scan = now;

            threads.deinit();
            try threads.init(.{ .allocator = allocator });

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

                threads.spawn(Device.runUpdate, .{
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

    pub const Info = struct {
        pub const Details = struct {
            const script = @embedFile("collect.sh");

            build_number: u32,
            sudo_nopasswd: bool,
            code_name: []const u8,
            product_family: []const u8,
            bios_version: []const u8,
            jira_objective: []const u8,

            fn init(input: []const u8, allocator: std.mem.Allocator) !Details {
                var result = std.mem.zeroes(Details);
                var lines = std.mem.splitScalar(u8, input, '\n');

                while (lines.next()) |line| {
                    var parts = std.mem.splitScalar(u8, line, '=');
                    const key = parts.next() orelse continue;
                    const value = parts.next() orelse continue;

                    if (std.mem.eql(u8, key, "BUILD_NUMBER")) {
                        result.build_number = std.fmt.parseInt(u32, value, 0) catch 0;
                    } else if (std.mem.eql(u8, key, "SUDO_NOPASSWD")) {
                        result.sudo_nopasswd = std.mem.eql(u8, value, "true");
                    } else if (std.mem.eql(u8, key, "PLATFORM_CODENAME")) {
                        result.code_name = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "PRODUCT_FAMILY")) {
                        result.product_family = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "BIOS_VERSION")) {
                        result.bios_version = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "JIRA_OBJECTIVE")) {
                        result.jira_objective = try allocator.dupe(u8, value);
                    }
                }

                return result;
            }

            fn deinit(self: Details, allocator: std.mem.Allocator) void {
                allocator.free(self.code_name);
                allocator.free(self.product_family);
                allocator.free(self.bios_version);
                allocator.free(self.jira_objective);
            }
        };

        name: []const u8,
        mac: ARP.Mac,
        lab_device: bool,
        last_seen: i64,
        details: ?Details = null,
    };

    ip: ARP.Ip4,
    allocator: std.mem.Allocator,
    info: ?Info,

    fn refresh(dev: Device) bool {
        if (dev.info) |info| {
            const elapsed = std.time.timestamp() - info.last_seen;
            const ttl: i64 = if (info.lab_device) LAB_DEVICE_TTL else UNKNOWN_DEVICE_TTL;
            return elapsed > ttl;
        }
        return true;
    }

    fn update(dev: *Device, mac: ARP.Mac, user: [:0]const u8, key: ssh.Key) !void {
        var buffer: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

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

        _ = try session.spawn("hostname", stream.writer());
        const hostname = std.mem.trimRight(u8, stream.getWritten(), "\n");

        if (dev.info) |info| {
            if (!info.lab_device)
                dev.allocator.free(info.name);
            if (info.details) |details|
                details.deinit(dev.allocator);
        }
        var info = Info{
            .name = try dev.allocator.dupe(u8, hostname),
            .mac = mac,
            .lab_device = true,
            .last_seen = now,
        };
        defer dev.info = info;
        log.info("lab device: {s}", .{hostname});

        stream.reset();
        switch (try session.spawn(Info.Details.script, stream.writer())) {
            0 => info.details = try Info.Details.init(stream.getWritten(), dev.allocator),
            else => {},
        }
    }

    fn runUpdate(dev: *Device, mac: ARP.Mac, user: [:0]const u8, key: ssh.Key) void {
        dev.update(mac, user, key) catch |err| {
            log.err("update {}: {}", .{ ARP.stringify(dev.ip), err });
        };
    }
};
