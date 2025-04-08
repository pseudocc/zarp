const std = @import("std");
const ARP = @import("ARP.zig");
const builtin = @import("builtin");

const os = std.os.linux;
const posix = std.posix;
const native_endian = builtin.cpu.arch.endian();

const log = std.log.scoped(.@"unix-socket");

const Request = enum(u8) {
    list,
    rescan,
};

const Response = struct {
    client: os.fd_t,
    request: Request,

    pub fn list(self: Response, devices: []const Device) !void {
        const file = std.fs.File{ .handle = self.client };
        const writer = file.writer();

        try writer.writeInt(u32, @intCast(devices.len), native_endian);
        for (devices) |device| {
            try writer.writeByte(@intFromBool(device.online));
            try writer.writeInt(ARP.Ip4, device.ip, native_endian);
            for (device.mac) |byte| {
                try writer.writeByte(byte);
            }
            try writer.writeAll(device.name);
            try writer.writeByte(0);
        }
    }

    pub fn ok(self: Response, success: bool) !void {
        const byte: u8 = @intFromBool(success);
        _ = try posix.write(self.client, &.{byte});
    }
};

pub const Device = struct {
    online: bool,
    ip: ARP.Ip4,
    mac: ARP.Mac,
    name: []const u8,

    pub fn jsonStringify(self: *const Device, writer: anytype) !void {
        // use a wrapper class to make thing easier
        const JsObject = struct {
            ip: []const u8,
            mac: []const u8,
            name: []const u8,
        };

        var ip_buffer: [16]u8 = undefined;
        var mac_buffer: [18]u8 = undefined;

        try writer.write(JsObject{
            .ip = try std.fmt.bufPrint(&ip_buffer, "{}", .{ARP.stringify(self.ip)}),
            .mac = try std.fmt.bufPrint(&mac_buffer, "{}", .{ARP.stringify(self.mac)}),
            .name = self.name,
        });
    }
};

const Socket = struct {
    const Name = "yolo.socket";
    fd: os.fd_t,

    fn init(comptime create: bool) !Socket {
        const cwd = std.fs.cwd();
        var sa = posix.sockaddr.un{
            .family = os.AF.UNIX,
            .path = undefined,
        };
        const rt_path = try std.fmt.bufPrintZ(&sa.path, "/run/zarp", .{});
        _ = try std.fmt.bufPrintZ(sa.path[rt_path.len..], "/{s}", .{Name});

        const dir = cwd.openDir(rt_path, .{}) catch |err| {
            if (err == error.FileNotFound)
                log.err("failed to open {s}", .{rt_path});
            return err;
        };
        const socket_path = std.mem.sliceTo(&sa.path, 0);

        if (create) {
            dir.deleteFile(Name) catch |err| {
                if (err != error.FileNotFound)
                    return err;
            };
        } else {
            // ensure the socket file is present
            _ = dir.statFile(Name) catch |err| {
                if (err == error.FileNotFound)
                    log.err("socket file not found: {s}", .{socket_path});
                return err;
            };
        }

        const addr = std.net.Address{ .un = sa };
        const fd = try posix.socket(os.AF.UNIX, os.SOCK.STREAM, os.PF.UNIX);
        errdefer posix.close(fd);

        if (create) {
            log.info("binding & listening on UNIX socket {s}", .{socket_path});
            try posix.bind(fd, &addr.any, addr.getOsSockLen());
            try posix.listen(fd, os.SOMAXCONN);
        } else {
            log.debug("connecting to UNIX socket {s}", .{socket_path});
            try posix.connect(fd, &addr.any, addr.getOsSockLen());
        }

        return .{ .fd = fd };
    }

    fn deinit(self: Socket) void {
        posix.close(self.fd);
    }
};

pub const Daemon = struct {
    socket: Socket,

    pub fn init() !Daemon {
        const socket = Socket.init(true) catch |err| {
            log.err("inner error: {}", .{err});
            return error.SocketInit;
        };
        return .{ .socket = socket };
    }

    pub fn deinit(self: Daemon) void {
        posix.close(self.socket.fd);
    }

    pub fn accept(self: Daemon) !?Response {
        var pollfd = os.pollfd{
            .fd = self.socket.fd,
            .events = os.POLL.IN,
            .revents = 0,
        };

        if (os.poll(@ptrCast(&pollfd), 1, 100) <= 0)
            return null;

        const client = try posix.accept(self.socket.fd, null, null, os.SOCK.CLOEXEC);
        log.debug("accepted client: fd={}", .{client});

        const file = std.fs.File{ .handle = client };
        const byte = try file.reader().readByte();
        const request = try std.meta.intToEnum(Request, byte);
        return .{
            .client = client,
            .request = request,
        };
    }
};

pub const Client = struct {
    socket: Socket,

    pub fn init() !Client {
        const socket = Socket.init(false) catch |err| {
            log.err("inner error: {}", .{err});
            return error.SocketInit;
        };
        return .{ .socket = socket };
    }

    pub fn deinit(self: Client) void {
        posix.close(self.socket.fd);
    }

    pub fn list(self: Client, allocator: std.mem.Allocator) !?[]const Device {
        const file = std.fs.File{ .handle = self.socket.fd };
        const writer = file.writer();
        const reader = file.reader();

        try writer.writeByte(@intFromEnum(Request.list));
        log.debug("sent list request", .{});

        const n_devices = try reader.readInt(u32, native_endian);
        const devices = try allocator.alloc(Device, n_devices);
        for (devices) |*device| {
            device.online = try reader.readByte() == @intFromBool(true);
            device.ip = try reader.readInt(ARP.Ip4, native_endian);
            for (&device.mac) |*byte| {
                byte.* = try reader.readByte();
            }
            device.name = try reader.readUntilDelimiterAlloc(allocator, 0, 256);
        }
        return devices;
    }

    pub fn rescan(self: Client) !bool {
        const file = std.fs.File{ .handle = self.socket.fd };
        const writer = file.writer();
        const reader = file.reader();

        try writer.writeByte(@intFromEnum(Request.rescan));
        log.debug("sent rescan request", .{});

        return try reader.readByte() == @intFromBool(true);
    }
};
