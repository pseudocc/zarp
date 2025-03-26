const std = @import("std");
const if_arp = @import("linux_if_arp");

const os = std.os.linux;
const errno = os.E.init;

const log = std.log.scoped(.netlink);
const sockaddr = os.sockaddr.nl;

pub const ifaddrmsg = extern struct {
    family: u8,
    prefix_len: u8,
    flags: u8,
    scope: u8,
    index: i32,
};

pub const rtmsg = extern struct {
    family: u8,
    dst_len: u8,
    src_len: u8,
    tos: u8,
    table: u8,
    protocol: u8,
    scope: u8,
    type: u8,
    flags: u32,
};

const socket = struct {
    const Options = struct {
        close_on_exec: bool = false,
        protocol: u32 = os.NETLINK.ROUTE,
    };

    fn open(options: Options) !os.fd_t {
        const socket_type = z: {
            var base: u32 = os.SOCK.RAW;
            if (options.close_on_exec)
                base |= os.SOCK.CLOEXEC;
            break :z base;
        };
        const rc = os.socket(os.AF.NETLINK, socket_type, options.protocol);
        return switch (errno(rc)) {
            .SUCCESS => |case| good: {
                log.debug("socket.open() -> {s}", .{@tagName(case)});
                break :good @intCast(rc);
            },
            else => |case| bad: {
                log.err("socket.open() -> {s}", .{@tagName(case)});
                break :bad error.SocketOpen;
            },
        };
    }

    fn close(fd: os.fd_t) void {
        const rc = os.close(fd);
        switch (errno(rc)) {
            .SUCCESS => |case| log.debug("socket.close({}) -> {s}", .{ fd, @tagName(case) }),
            else => |case| log.err("socket.close({}) -> {s}", .{ fd, @tagName(case) }),
        }
    }

    fn addr() sockaddr {
        return .{
            .family = os.AF.NETLINK,
            .pid = 0,
            .groups = 0,
        };
    }

    fn bind(fd: os.fd_t) !void {
        const sa = addr();
        const rc = os.bind(fd, @ptrCast(&sa), @sizeOf(sockaddr));
        if (rc < 0) {
            log.err("socket.bind({}) -> {}", .{ fd, errno(rc) });
            return error.SocketBind;
        }
        log.debug("socket.bind({}) -> SUCCESS", .{fd});
    }

    fn sendmsg(fd: os.fd_t, msg: *const os.msghdr_const) !usize {
        const rc = os.sendmsg(fd, msg, 0);
        return switch (errno(rc)) {
            .SUCCESS => good: {
                log.debug("socket.sendmsg({}) -> {}", .{ fd, rc });
                break :good @intCast(rc);
            },
            .INTR => |case| retry: {
                log.warn("socket.sendmsg({}) -> {s}", .{ fd, @tagName(case) });
                break :retry error.SocketSendRetry;
            },
            else => |case| bad: {
                log.err("socket.sendmsg({}) -> {s}", .{ fd, @tagName(case) });
                break :bad error.SocketSend;
            },
        };
    }

    fn recvmsg(fd: os.fd_t, msg: *os.msghdr) !usize {
        const rc = os.recvmsg(fd, msg, 0);
        return switch (errno(rc)) {
            .SUCCESS => good: {
                log.debug("socket.recvmsg({}) -> {}", .{ fd, rc });
                break :good @intCast(rc);
            },
            .INTR => |case| retry: {
                log.warn("socket.recvmsg({}) -> {s}", .{ fd, @tagName(case) });
                break :retry error.SocketRecvRetry;
            },
            else => |case| bad: {
                log.err("socket.recvmsg({}) -> {s}", .{ fd, @tagName(case) });
                break :bad error.SocketRecv;
            },
        };
    }
};

const Attribute = struct {
    const Self = @This();

    header: os.rtattr align(4),
    payload: void align(4),

    pub fn as(self: *const Self, comptime P: type) *const P {
        return @ptrCast(&self.payload);
    }

    pub fn asSlice(self: *const Self, comptime P: type, comptime sentinel: P) []const P {
        const ptr: [*:sentinel]const P = @ptrCast(&self.payload);
        return std.mem.span(ptr);
    }
};

pub fn Message(comptime T: type) type {
    const Header = os.nlmsghdr;
    return extern struct {
        const Self = @This();

        header: Header align(4),
        payload: T align(4),

        pub fn as(self: *const Self, comptime P: type) *const P {
            if (T != void)
                @compileError("Only works for void payloads");
            return @ptrCast(&self.payload);
        }

        pub fn messages(self: *const Self, len: usize) Iterator(Header) {
            return Iterator(Header).init(&self.header, len);
        }

        pub fn attributes(self: *const Self) Iterator(os.rtattr) {
            const offset: usize = z: {
                const o0 = std.mem.alignForward(usize, @sizeOf(os.nlmsghdr), 4);
                const sz: usize = switch (self.header.type) {
                    .RTM_NEWLINK, .RTM_DELLINK => @sizeOf(os.ifinfomsg),
                    .RTM_NEWADDR, .RTM_DELADDR => @sizeOf(ifaddrmsg),
                    .RTM_NEWROUTE, .RTM_DELROUTE => @sizeOf(rtmsg),
                    else => unreachable,
                };
                const o1 = std.mem.alignForward(usize, sz, 4);
                break :z o0 + o1;
            };
            const raw: [*]align(4) const u8 = @ptrCast(&self.header);
            const attr_raw: [*]align(4) const u8 = @alignCast(raw[offset..]);
            return Iterator(os.rtattr).init(@ptrCast(attr_raw), self.header.len - offset);
        }
    };
}

pub const Request = struct {
    const Self = @This();

    sa: sockaddr,
    buffer: []align(4) u8,

    pub fn init(buffer: []align(4) u8) Self {
        return .{
            .sa = socket.addr(),
            .buffer = buffer,
        };
    }

    const WrappedIterator = struct {
        req: *const Self,
        fd: os.fd_t,
        iter: Iterator(os.nlmsghdr),

        pub fn next(self: *WrappedIterator) !?*const Message(void) {
            while (true) {
                if (self.iter.next()) |msg|
                    return msg;
                var riov: std.posix.iovec = .{
                    .base = @ptrCast(self.req.buffer),
                    .len = self.req.buffer.len,
                };
                var msg: os.msghdr = std.mem.zeroInit(os.msghdr, .{
                    .name = @as(*os.sockaddr, @constCast(@ptrCast(&self.req.sa))),
                    .namelen = @sizeOf(sockaddr),
                    .iov = @as([*]std.posix.iovec, @ptrCast(&riov)),
                    .iovlen = 1,
                });

                const n = socket.recvmsg(self.fd, &msg) catch break;
                const response: *const Message(void) = @ptrCast(self.req.buffer);

                // handle control message first
                switch (response.header.type) {
                    .ERROR => return error.NetlinkError,
                    .DONE => break,
                    .OVERRUN => return error.BufferTooSmall,
                    else => {},
                }

                self.iter = response.messages(n);
            }

            // make compiler happy
            return null;
        }

        pub fn deinit(self: *WrappedIterator) void {
            socket.close(self.fd);
        }
    };

    pub fn get(self: *const Self, msgtype: os.NetlinkMessageType) !WrappedIterator {
        const req: Message(rtgenmsg) = .{
            .header = .{
                .len = @sizeOf(Message(rtgenmsg)),
                .type = msgtype,
                .flags = os.NLM_F_REQUEST | os.NLM_F_DUMP,
                .seq = 1,
                .pid = 0,
            },
            .payload = .{ .family = os.AF.PACKET },
        };

        const iovec = std.posix.iovec_const;
        const msg: os.msghdr_const = std.mem.zeroInit(os.msghdr_const, .{
            .name = @as(*const os.sockaddr, @ptrCast(&self.sa)),
            .namelen = @sizeOf(sockaddr),
            .iov = @as([*]const iovec, @ptrCast(&iovec{
                .base = @ptrCast(&req),
                .len = req.header.len,
            })),
            .iovlen = 1,
        });

        const fd = try socket.open(.{});
        try socket.bind(fd);

        _ = try socket.sendmsg(fd, &msg);
        return WrappedIterator{
            .req = self,
            .fd = fd,
            .iter = Iterator(os.nlmsghdr).init(@ptrCast(self.buffer), 0),
        };
    }
};

pub fn Iterator(comptime T: type) type {
    if (!@hasField(T, "len"))
        @compileError("Underlying type requires a 'len' field");

    return struct {
        const Self = @This();

        header: *align(4) const T,
        remain: usize,

        const NextReturn = switch (T) {
            os.nlmsghdr => Message(void),
            os.rtattr => Attribute,
            else => unreachable,
        };

        pub fn init(header: *align(4) const T, len: usize) Iterator(T) {
            return .{
                .header = header,
                .remain = len,
            };
        }

        pub fn next(self: *Self) ?*const NextReturn {
            const r = self.remain;
            if (r < @sizeOf(T))
                return null;
            const l = self.header.len;
            if (r < l or l < @sizeOf(T))
                return null;
            const raw: [*]align(4) const u8 = @ptrCast(self.header);
            const offset = std.mem.alignForward(usize, l, 4);
            const next_raw: [*]align(4) const u8 = @alignCast(raw[offset..]);
            defer {
                self.remain = if (r > l) r - l else 0;
                self.header = @ptrCast(next_raw);
            }
            return @ptrCast(self.header);
        }
    };
}

const rtgenmsg = extern struct {
    family: u8,
};
