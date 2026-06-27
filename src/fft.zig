const std = @import("std");

pub const Result = struct {
    magnitudes: ?[]f32,
    sample_count: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.magnitudes) |magnitudes| {
            allocator.free(magnitudes);
        }
    }
};

fn transfer(allocator: std.mem.Allocator, sample_points: ?*f32, count: usize) ?Result {
    _ = allocator;
    _ = sample_points;
    _ = count;

    return .{
        .magnitudes = null,
        .sample_count = 0,
    };
}

pub fn fft(allocator: std.mem.Allocator, sample_points: ?*f32, count: usize) ?Result {
    if (count == 0) return null;
    return transfer(allocator, sample_points, count);
}
