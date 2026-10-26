const std = @import("std");

fn fill(m: []i64, n: i64, seed: i64) void {
    var i: i64 = 0;
    while (i < n * n) : (i += 1) m[@intCast(i)] = @rem(i * seed + 7, 100);
}

pub fn main() !void {
    const a = std.heap.c_allocator;
    const n: i64 = 800;
    const len: usize = @intCast(n * n);
    const x = try a.alloc(i64, len);
    const y = try a.alloc(i64, len);
    const z = try a.alloc(i64, len);
    defer a.free(z);
    @memset(z, 0);
    fill(x, n, 3);
    fill(y, n, 5);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        var k: i64 = 0;
        while (k < n) : (k += 1) {
            const xik = x[@intCast(i * n + k)];
            var j: i64 = 0;
            while (j < n) : (j += 1) z[@intCast(i * n + j)] += xik * y[@intCast(k * n + j)];
        }
    }
    a.free(x);
    a.free(y);
    var sum: i64 = 0;
    for (z) |v| sum = @rem(sum + v, 1000000007);
    std.debug.print("{d}\n", .{sum});
}
