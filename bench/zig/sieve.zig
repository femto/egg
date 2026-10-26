const std = @import("std");

fn countPrimes(a: std.mem.Allocator, n: usize) !i64 {
    const composite = try a.alloc(bool, n + 1);
    defer a.free(composite);
    @memset(composite, false);
    var count: i64 = 0;
    var i: usize = 2;
    while (i <= n) : (i += 1) {
        if (!composite[i]) {
            count += 1;
            var j = i * i;
            while (j <= n) : (j += i) composite[j] = true;
        }
    }
    return count;
}

pub fn main() !void {
    std.debug.print("{d}\n", .{try countPrimes(std.heap.c_allocator, 50000000)});
}
