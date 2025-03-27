const ARP = @This();

const std = @import("std");
const os = std.os.linux;
const if_arp = @import("linux_if_arp");

const errno = os.E.init;
const log = std.log.scoped(.arp);

const Protocol = std.mem.nativeToBig(u16, if_arp.ETH_P_ARP);
const sockaddr = os.sockaddr.ll;

pub const Mac = [6]u8;
pub const Ip4 = u32;

pub const Device = struct {
    const Hardware = struct {
        address: Mac,
        broadcast: Mac,
    };

    const SubnetIterator = struct {
        current: Ip4,
        end: Ip4,

        pub fn next(self: *SubnetIterator) ?Ip4 {
            if (self.current >= self.end)
                return null;
            defer self.current += 1;
            return std.mem.nativeToBig(Ip4, self.current);
        }
    };

    index: i32,
    prefix_len: u8,
    ip: Ip4,
    hardware: Hardware,

    pub fn subnet(device: Device) SubnetIterator {
        const host_bits: u5 = @intCast(32 - device.prefix_len);
        const base = std.mem.bigToNative(Ip4, device.ip);
        const mask = ~@as(Ip4, 0) << host_bits;
        const network = base & mask;
        const n_hosts = @as(u32, 1) << host_bits;
        return .{
            .current = network + 1,
            .end = network + n_hosts,
        };
    }
};

socket: os.fd_t,
device: Device,

pub fn init(device: Device) !ARP {
    const socket: os.fd_t = z: {
        const rc = os.socket(os.AF.PACKET, os.SOCK.RAW, Protocol);
        switch (errno(rc)) {
            .SUCCESS => break :z @intCast(rc),
            else => |case| {
                log.err("init: os.socket() -> {s}", .{@tagName(case)});
                return error.SocketCreation;
            },
        }
    };

    {
        const sall = std.mem.zeroInit(sockaddr, .{
            .family = os.AF.PACKET,
            .ifindex = device.index,
        });
        const sa: *const os.sockaddr = @ptrCast(&sall);
        const rc = os.bind(socket, sa, @sizeOf(sockaddr));
        switch (errno(rc)) {
            .SUCCESS => log.debug("init: os.bind({}, {}) -> SUCCESS", .{ socket, device.index }),
            else => |case| {
                log.err("init: os.bind({}, {}) -> {s}", .{ socket, device.index, @tagName(case) });
                return error.SocketBind;
            },
        }
    }

    return .{
        .socket = socket,
        .device = device,
    };
}

pub fn deinit(arp: ARP) void {
    const rc = os.close(arp.socket);
    switch (errno(rc)) {
        .SUCCESS => log.debug("deinit: os.close({}) -> SUCCESS", .{arp.socket}),
        else => |case| log.err("deinit: os.close({}) -> {s}", .{ arp.socket, @tagName(case) }),
    }
}

pub const Packet = extern struct {
    eth: if_arp.ethhdr align(2),
    arp: if_arp.arphdr align(2) = .{
        .ar_hrd = std.mem.nativeToBig(u16, if_arp.ARPHRD_ETHER),
        .ar_pro = std.mem.nativeToBig(u16, if_arp.ETH_P_IP),
        .ar_hln = @sizeOf(Mac),
        .ar_pln = @sizeOf(Ip4),
        .ar_op = std.mem.nativeToBig(u16, if_arp.ARPOP_REQUEST),
    },
    sender: Record align(2),
    target: Record align(2),
};

pub const Record = extern struct {
    mac: Mac align(2),
    ip: Ip4 align(2),
};

pub fn send(arp: ARP, to: Ip4) !void {
    const packet = Packet{
        .eth = .{
            .h_dest = arp.device.hardware.broadcast,
            .h_source = arp.device.hardware.address,
            .h_proto = Protocol,
        },
        .sender = .{
            .mac = arp.device.hardware.address,
            .ip = arp.device.ip,
        },
        .target = .{
            .mac = std.mem.zeroes(Mac),
            .ip = to,
        },
    };

    const sall = z: {
        var v = sockaddr{
            .family = os.AF.PACKET,
            .protocol = Protocol,
            .ifindex = arp.device.index,
            .hatype = std.mem.nativeToBig(u16, if_arp.ARPHRD_ETHER),
            .pkttype = if_arp.PACKET_BROADCAST,
            .halen = @sizeOf(Mac),
            .addr = undefined,
        };
        @memcpy(v.addr[0..@sizeOf(Mac)], &packet.eth.h_source);
        @memset(v.addr[@sizeOf(Mac)..], 0);
        break :z v;
    };
    const sa: *const os.sockaddr = @ptrCast(&sall);
    const rc = os.sendto(arp.socket, @ptrCast(&packet), @sizeOf(Packet), 0, sa, @sizeOf(sockaddr));
    switch (errno(rc)) {
        .SUCCESS => {
            if (rc != @sizeOf(Packet)) {
                log.err("send({}): os.sendto() -> short write", .{stringify(to)});
                return error.ShortWrite;
            }
            log.debug("send: {} -> SUCCESS", .{stringify(to)});
        },
        .AGAIN => {
            log.warn("send({}): os.sendto() -> EAGAIN", .{stringify(to)});
            return error.Retry;
        },
        else => |case| {
            log.err("send({}): os.sendto() -> {s}", .{ stringify(to), @tagName(case) });
            return error.Sendto;
        },
    }
}

pub fn receive(arp: ARP) !Packet {
    var packet: Packet = undefined;
    const rc = os.recvfrom(arp.socket, @ptrCast(&packet), @sizeOf(Packet), 0, null, null);
    switch (errno(rc)) {
        .SUCCESS => {
            if (rc != @sizeOf(Packet)) {
                log.warn("receive: os.recvfrom() -> short read", .{});
                return error.Malformed;
            }
        },
        else => |case| {
            log.err("receive: os.recvfrom() -> {s}", .{@tagName(case)});
            return error.Recvfrom;
        },
    }

    if (packet.eth.h_proto != Protocol) {
        log.warn("receive: h_proto: {}", .{std.mem.bigToNative(u16, packet.eth.h_proto)});
        return error.NotArp;
    }
    if (packet.arp.ar_op != std.mem.nativeToBig(u16, if_arp.ARPOP_REPLY)) {
        log.warn("receive: ar_op: {}", .{std.mem.bigToNative(u16, packet.arp.ar_op)});
        return error.NotReply;
    }

    return packet;
}

fn StringView(comptime T: type) type {
    switch (T) {
        Mac, Ip4 => {},
        else => @compileError("Unsupported type"),
    }

    return struct {
        underlying: T,

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            _: std.fmt.FormatOptions,
            out_stream: anytype,
        ) !void {
            const cprint = std.fmt.comptimePrint;

            const FormatParams = struct {
                fmt: []const u8,
                delim: u8,
            };

            const params: FormatParams = comptime switch (T) {
                Mac => mac: {
                    const mac_fmt: []const u8 = switch (fmt.len) {
                        0 => "{X:0>2}",
                        1 => has_fmt: {
                            if (std.ascii.toLower(fmt[0]) == 'x')
                                break :has_fmt cprint("{{{s}:0>2}}", .{fmt});
                            std.fmt.invalidFmtError(fmt, self);
                        },
                        else => std.fmt.invalidFmtError(fmt, self),
                    };
                    break :mac .{ .fmt = mac_fmt, .delim = ':' };
                },
                Ip4 => .{ .fmt = "{d}", .delim = '.' },
                else => unreachable,
            };

            const bytes = std.mem.asBytes(&self.underlying);
            var first = true;
            for (bytes) |byte| {
                if (!first)
                    try std.fmt.format(out_stream, "{c}", .{params.delim});
                try std.fmt.format(out_stream, params.fmt, .{byte});
                first = false;
            }
        }
    };
}

pub fn stringify(value: anytype) StringView(@TypeOf(value)) {
    return StringView(@TypeOf(value)){ .underlying = value };
}

pub fn request(arp: ARP, to: Ip4, retries: usize) !?Packet {
    for (0..retries) |_| {
        try arp.send(to);

        var pollfd = os.pollfd{
            .fd = arp.socket,
            .events = os.POLL.IN,
            .revents = 0,
        };

        if (os.poll(@ptrCast(&pollfd), 1, 500) <= 0)
            continue;

        const packet = arp.receive() catch |err| {
            if (err == error.NotReply)
                continue;
            return err;
        };

        return packet;
    }

    return null;
}

pub const IFF = packed struct(c_uint) {
    up: bool,
    broadcast: bool,
    debug: bool,
    loopback: bool,
    pointopoint: bool,
    notrailers: bool,
    running: bool,
    noarp: bool,
    promisc: bool,
    allmulti: bool,
    master: bool,
    slave: bool,
    multicast: bool,
    portsel: bool,
    automedia: bool,
    dynamic: bool,
    lowerup: bool,
    dormant: bool,
    echo: bool,
    _unused: u13,
};
