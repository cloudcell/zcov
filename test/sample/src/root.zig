// Integration test sample: add and multiply are tested, subtract is not.
// zig-cov should report line 2 and line 10 as hit, line 6 as not hit.
const math = @import("math.zig");
const std = @import("std");

test "add" {
    try std.testing.expectEqual(@as(i32, 5), math.add(2, 3));
}

test "multiply" {
    try std.testing.expectEqual(@as(i32, 6), math.multiply(2, 3));
}
