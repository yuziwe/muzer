const std = @import("std");

fn add(x: u8, y: u8) u8 {
    return x + y;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, stdout_buffer[0..]);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s} {d}!\n", .{ "Hello, muzer", add(34, 35) });
    try stdout.flush();
}

test "Simple add" {
    try std.testing.expectEqual(69, add(34, 35));
}

