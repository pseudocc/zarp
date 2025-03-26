const std = @import("std");
const libssh = @import("libssh");

const log = std.log.scoped(.libssh);

pub const Session = struct {
    underlying: libssh.ssh_session,

    pub fn init(
        host: [:0]const u8,
        user: [:0]const u8,
        password: [:0]const u8,
    ) !Session {
        log.debug("init", .{});
        const session = libssh.ssh_new() orelse return error.SSHSessionInit;
        errdefer libssh.ssh_free(session);
        log.debug("session: {p}", .{session});

        _ = libssh.ssh_options_set(
            session,
            libssh.SSH_OPTIONS_HOST,
            @ptrCast(host),
        );
        _ = libssh.ssh_options_set(
            session,
            libssh.SSH_OPTIONS_USER,
            @ptrCast(user),
        );

        switch (libssh.ssh_connect(session)) {
            libssh.SSH_OK => {},
            else => return error.SSHConnect,
        }
        errdefer libssh.ssh_disconnect(session);

        switch (libssh.ssh_userauth_password(session, null, password)) {
            libssh.SSH_AUTH_SUCCESS => {},
            else => return error.SSHAuth,
        }

        return .{ .underlying = session };
    }

    pub fn deinit(self: Session) void {
        libssh.ssh_disconnect(self.underlying);
        libssh.ssh_free(self.underlying);
    }

    pub fn channel(self: Session) !Channel {
        return Channel.init(self);
    }
};

const Channel = struct {
    underlying: libssh.ssh_channel,

    fn init(session: Session) !Channel {
        const channel = libssh.ssh_channel_new(session.underlying) orelse return error.SSHChannelInit;
        errdefer libssh.ssh_channel_free(channel);

        switch (libssh.ssh_channel_open_session(channel)) {
            libssh.SSH_OK => {},
            else => return error.SSHChannelOpen,
        }

        return .{ .underlying = channel };
    }

    pub fn deinit(self: Channel) void {
        libssh.ssh_channel_close(self.underlying);
        libssh.ssh_channel_free(self.underlying);
    }

    pub fn exec(self: Channel, command: [:0]const u8) !void {
        switch (libssh.ssh_channel_request_exec(self.underlying, command)) {
            libssh.SSH_OK => {},
            else => return error.SSHChannelExec,
        }
    }

    const Output = enum {
        stdout,
        stderr,
    };
    pub fn read(self: Channel, writer: anytype, output: Output) !void {
        var buffer: [256]u8 = undefined;
        const buffer_cptr: [*c]u8 = &buffer;
        while (true) {
            const rc = libssh.ssh_channel_read(self.underlying, buffer_cptr, buffer.len, @intFromEnum(output));
            if (rc < 0)
                return error.SSHChannelRead;
            if (rc == 0)
                break;
            const bytes_read: usize = @intCast(rc);
            try writer.writeAll(buffer[0..bytes_read]);
        }
    }
};
