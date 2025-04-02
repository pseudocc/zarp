const std = @import("std");
const Z = @import("zargs");
const ARP = @import("ARP.zig");
const cli = @import("cli.zig");

pub const std_options = std.Options{
    .log_scope_levels = &.{
        .{ .scope = .zargs, .level = .info },
        .{ .scope = .arp, .level = .info },
        .{ .scope = .netlink, .level = .info },
    },
};

const Commands = union(enum) {
    const Daemon = @import("daemon.zig").Daemon;
    const List = cli.List;

    daemon: Daemon,
    list: List,
    rescan,

    pub fn summary(active: std.meta.Tag(@This())) Z.string {
        return switch (active) {
            .daemon => Daemon.zargs.summary,
            .list => List.zargs.summary,
            .rescan => "Rescan for lab devices.",
        };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var parser = Z.init(allocator, std.os.argv);
    defer parser.deinit();

    const args = parser.parse(Commands);
    if (args == Z.ParseError.HelpRequested)
        return;

    switch (try args) {
        .daemon => |daemon| try daemon.listen(),
        .list => |client| try client.list(),
        .rescan => try cli.rescan(),
    }
}
