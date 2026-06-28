const std = @import("std");
const Complex = std.math.complex.Complex;
const EXP = std.math.complex.exp;
const PI = std.math.pi;

const FFTError = error{ InvalidPadding, OutOfMemory };

pub const Result = struct {
    magnitudes: ?[]f32,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.magnitudes) |magnitudes| {
            allocator.free(magnitudes);
        }
    }
};

fn log2(n: usize) usize {
    var s: usize = 1;
    while ((@as(usize, 1) << @truncate(s)) < n) : (s += 1) {}
    return s;
}

fn reverseBit(x: usize, n: usize) usize {
    var r: usize = 0;
    var xx = x;
    for (0..n) |_| {
        r = (r << 1) | (xx & 1);
        xx >>= 1;
    }
    return r;
}

fn bitReverseCopy(allocator: std.mem.Allocator, input: []const Complex(f32)) FFTError![]Complex(f32) {
    if (@popCount(input.len) != 1) return FFTError.InvalidPadding;

    var A = try allocator.alloc(Complex(f32), input.len);

    const n = log2(input.len);
    for (0..input.len) |k| {
        A[reverseBit(k, n)] = input[k];
    }

    return A;
}

fn iterativeFFT(allocator: std.mem.Allocator, input: []const Complex(f32)) ![]Complex(f32) {
    if (@popCount(input.len) != 1) return FFTError.InvalidPadding;

    var A = try bitReverseCopy(allocator, input);

    var s: usize = 1;
    while ((@as(usize, 1) << @truncate(s)) <= input.len) : (s += 1) {
        const m: usize = @as(usize, 1) << @truncate(s);
        const im: f32 = @divTrunc(-2 * PI, @as(f32, @floatFromInt(m)));
        const wm = EXP(Complex(f32).init(0, im));

        var k: usize = 0;
        while (m * k < input.len) : (k += 1) {
            var w = Complex(f32).init(0, 1);

            var j: usize = 0;
            while (2 * (j + 1) < m) : (j += 1) {
                const t = w.mul(A[k + j + m / 2]);
                const u = A[k + j];
                A[k + j] = u.add(t);
                A[k + j + m / 2] = u.sub(t);
                w = w.mul(wm);
            }
        }
    }

    return A;
}

fn next_pow2(n: usize) usize {
    var x = n;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x |= x >> 32;
    x += 1;
    return x;
}

fn transfer(allocator: std.mem.Allocator, sample_points: [*]f32, count: usize) ?Result {
    var padding_length: usize = count;
    if (@popCount(count) != 1) {
        // Align
        padding_length = next_pow2(count);
    }

    var fin = allocator.alloc(Complex(f32), padding_length) catch return null;
    defer allocator.free(fin);

    for (0..count) |i| {
        fin[i].re = sample_points[i];
        fin[i].im = 0.0;
    }

    const res = iterativeFFT(allocator, fin[0..]) catch return null;
    defer allocator.free(res);

    const fout = allocator.alloc(f32, padding_length) catch return null;

    for (res, fout) |cv, *v| {
        v.* = cv.squaredMagnitude();
    }

    return .{
        .magnitudes = fout,
    };
}

pub fn fft(allocator: std.mem.Allocator, sample_points: ?[*]f32, count: usize) ?Result {
    if (count == 0) return null;
    if (sample_points) |v| {
        return transfer(allocator, v, count);
    }
    return null;
}

test "bitReverseCopy" {
    const input: [4]Complex(f32) = .{
        .{
            .re = 0.1234,
            .im = 0,
        },
        .{
            .re = 0.4321,
            .im = 0,
        },
        .{
            .re = 0.5678,
            .im = 0,
        },
        .{
            .re = 0.8765,
            .im = 0,
        },
    };

    const output = try bitReverseCopy(std.testing.allocator, input[0..]);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(input[0], output[0]);
    try std.testing.expectEqual(input[2], output[1]);
    try std.testing.expectEqual(input[1], output[2]);
    try std.testing.expectEqual(input[3], output[3]);
}

test "bitReverseCopy-bound" {
    const input: [3]Complex(f32) = .{
        .{
            .re = 0.1234,
            .im = 0,
        },
        .{
            .re = 0.4321,
            .im = 0,
        },
        .{
            .re = 0.5678,
            .im = 0,
        },
    };

    const output = bitReverseCopy(std.testing.allocator, input[0..]);
    try std.testing.expectEqual(FFTError.InvalidPadding, output);
}

test "iterativeFFT" {
    const input: [4]Complex(f32) = .{
        .{
            .re = 0.1234,
            .im = 0,
        },
        .{
            .re = 0.4321,
            .im = 0,
        },
        .{
            .re = 0.5678,
            .im = 0,
        },
        .{
            .re = 0.8765,
            .im = 0,
        },
    };

    const output = try iterativeFFT(std.testing.allocator, input[0..]);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(4, output.len);
}

test "next_pow2" {
    try std.testing.expectEqual(4, next_pow2(3));
    try std.testing.expectEqual(16, next_pow2(16));
    try std.testing.expectEqual(1024, next_pow2(900));
}
