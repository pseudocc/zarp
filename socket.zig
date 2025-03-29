const std = @import("std");
const ARP = @import("ARP.zig");
const builtin = @import("builtin");

const os = std.os.linux;
const posix = std.posix;
const native_endian = builtin.cpu.arch.endian();

const Request = enum(u8) {
    list,
    block,
    unblock,
};

const Response = struct {
    client: os.fd_t,
    request: Request,

    pub fn list(self: Response, devices: []const Device) !void {
        const file = std.fs.File{ .handle = self.client };
        const writer = file.writer();

        try writer.writeInt(u32, @intCast(devices.len), native_endian);
        for (devices) |device| {
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
        try posix.write(self.client.socket, &.{byte});
    }
};

pub const Device = struct {
    ip: ARP.Ip4,
    mac: ARP.Mac,
    name: []const u8,
};

fn socketPath(buffer: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buffer, "/run/user/{}/zarp.sock", .{os.geteuid()});
}

pub const Daemon = struct {
    socket: os.fd_t,

    pub fn init() !Daemon {
        var path_buffer: [32]u8 = undefined;
        const socket_path = try socketPath(&path_buffer);
        std.fs.cwd().deleteFile(socket_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        std.log.debug("socket path: {s}", .{socket_path});

        const sa = try std.net.Address.initUnix(socket_path);
        const socket = try posix.socket(os.AF.UNIX, os.SOCK.STREAM, os.PF.UNIX);
        errdefer posix.close(socket);

        try posix.bind(socket, &sa.any, sa.getOsSockLen());
        try posix.listen(socket, os.SOMAXCONN);

        return .{ .socket = socket };
    }

    pub fn deinit(self: Daemon) void {
        posix.close(self.socket);
    }

    pub fn accept(self: Daemon) !?Response {
        var pollfd = os.pollfd{
            .fd = self.socket,
            .events = os.POLL.IN,
            .revents = 0,
        };

        if (os.poll(@ptrCast(&pollfd), 1, 100) <= 0)
            return null;

        const client = try posix.accept(self.socket, null, null, os.SOCK.CLOEXEC);
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
    socket: os.fd_t,

    pub fn init() !Client {
        var path_buffer: [32]u8 = undefined;
        const socket_path = try socketPath(&path_buffer);

        // ensure the socket file is present
        _ = try std.fs.cwd().statFile(socket_path);

        const sa = try std.net.Address.initUnix(socket_path);
        const socket = try posix.socket(os.AF.UNIX, os.SOCK.STREAM, os.PF.UNIX);
        errdefer posix.close(socket);

        try posix.connect(socket, &sa.any, sa.getOsSockLen());
        return .{ .socket = socket };
    }

    pub fn list(self: Client, allocator: std.mem.Allocator) !?[]const Device {
        const file = std.fs.File{ .handle = self.socket };
        const writer = file.writer();
        const reader = file.reader();

        try writer.writeByte(@intFromEnum(Request.list));
        std.log.debug("sent list request", .{});

        const n_devices = try reader.readInt(u32, native_endian);
        const devices = try allocator.alloc(Device, n_devices);
        for (devices) |*device| {
            device.ip = try reader.readInt(ARP.Ip4, native_endian);
            for (&device.mac) |*byte| {
                byte.* = try reader.readByte();
            }
            device.name = try reader.readUntilDelimiterAlloc(allocator, 0, 256);
        }
        return devices;
    }

    pub fn block(self: Daemon, name: []const u8, undo: bool) !bool {
        const file = std.fs.File{ .handle = self.socket };
        const writer = file.writer();
        const reader = file.reader();

        const request: Request = if (undo) .unblock else .block;
        try writer.writeByte(@intFromEnum(request));
        try writer.writeAll(name);
        try writer.writeByte(0);
        return try reader.readByte() == @intFromBool(true);
    }
};
