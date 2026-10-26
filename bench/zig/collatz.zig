const std = @import("std");

fn steps(start: i64) i64 {
    var n = start;
    var s: i64 = 0;
    while (n != 1) : (s += 1) {
        if (@rem(n, 2) == 0) n = @divTrunc(n, 2) else n = 3 * n + 1;
    }
    return s;
}

pub fn main() void {
    var best: i64 = 0;
    var best_n: i64 = 0;
    var i: i64 = 1;
    while (i < 3000000) : (i += 1) {
        const s = steps(i);
        if (s > best) {
            best = s;
            best_n = i;
        }
    }
    std.debug.print("{d}\n{d}\n", .{ best_n, best });
}
