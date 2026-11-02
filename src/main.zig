const std = @import("std");
const shpl = @import("shpl");

pub fn main(init: std.process.Init) !void {
    errdefer |err| if (err == std.mem.Allocator.Error.OutOfMemory) std.debug.print("buy more ram lol\n", .{});

    const start = std.Io.Clock.now(.real, init.io);

    try shpl.inliner.inlineFile(try std.Io.Dir.cwd().openDir(init.io, "proj_example", .{}), init.io, init.gpa, "main.shpl");

    std.debug.print("\n{f}\n", .{ start.untilNow(init.io, .real) });
}
