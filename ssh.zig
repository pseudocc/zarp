const std = @import("std");
const libssh = @import("libssh");

const log = std.log.scoped(.libssh);

pub const Key = struct {
    underlying: libssh.ssh_key,

    pub fn init(path: [:0]const u8, passphrase: ?[:0]const u8) !Key {
        var key: libssh.ssh_key = null;
        const rc = libssh.ssh_pki_import_privkey_file(
            @ptrCast(path),
            @ptrCast(passphrase),
            null,
            null,
            &key,
        );
        return switch (rc) {
            libssh.SSH_OK => .{ .underlying = key },
            else => error.SSHPrivateKey,
        };
    }

    pub fn deinit(self: Key) void {
        libssh.ssh_key_free(self.underlying);
    }
};

pub const Session = struct {
    underlying: libssh.ssh_session,

    pub fn init(
        host: [:0]const u8,
        user: [:0]const u8,
        private_key: Key,
    ) !Session {
        const session = libssh.ssh_new() orelse return error.SSHSessionInit;
        errdefer libssh.ssh_free(session);

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
        _ = libssh.ssh_options_set(
            session,
            libssh.SSH_OPTIONS_TIMEOUT_USEC,
            &@as(u32, std.time.us_per_s),
        );

        switch (libssh.ssh_connect(session)) {
            libssh.SSH_OK => {},
            else => return error.SSHConnect,
        }
        errdefer libssh.ssh_disconnect(session);

        switch (libssh.ssh_userauth_publickey(session, null, private_key.underlying)) {
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
